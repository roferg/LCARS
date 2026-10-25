#!/usr/bin/env bash
#
# lcars-common.sh — shared, sourceable helpers used by both `lcars init` and
# `lcars update`. Keeping the canonical label set and the merge-preserving
# config writer in ONE place means update can extend an already-initialized repo
# with exactly the same labels/keys init would create — no drift, no duplication.
#
# This file defines functions and data only; it runs nothing on its own. Source
# it:
#
#     . "$(dirname "$0")/lcars-common.sh"
#
# Dependencies are read from the caller's environment so tests can stub them:
#   GH_BIN   the gh binary (callers set this from ${LCARS_GH_BIN:-gh})
#
# ---------------------------------------------------------------------------
# CANONICAL LABEL SET
# ---------------------------------------------------------------------------
# One source of truth for the LCARS GitHub labels: their names, group colours,
# and descriptions. Both init (first-time setup) and update (fill-the-gaps)
# create from this list, skipping any label already present on the repo.

LCARS_STAGE_COLOR="FF9900"
LCARS_TYPE_COLOR="4499FF"
LCARS_STATUS_COLOR="FF3344"
LCARS_REL_COLOR="9977FF"
LCARS_ROLE_COLOR="00B894"
# S203 — Number One. The first officer's own family, in the board's peach:
# `--lcars-peach` is the one warm accent no card state had claimed, and a forge
# label has no theme tokens to inherit, so the hex is written here once.
LCARS_XO_COLOR="FF9966"

LCARS_STAGE_LABELS="align research validate plan plan-review schedule implement verify done"
LCARS_TYPE_LABELS="feature bug"
LCARS_STATUS_LABELS="paused awaiting-human"
LCARS_REL_LABELS="linked"
LCARS_ROLE_LABELS="mission ticket"
# THE SCORE IS A LABEL (captain ruling): one source per fact — the label is the
# score, the comment is the report — so a REMOTE card reads the intent match off
# the listing the board already fetched, with no second forge call (S191).
LCARS_XO_LABELS="xo:high xo:medium xo:low xo:engaged"

lcars_label_desc() {
  case "$1" in
    lcars:align)          echo "Stage: aligning on the mission goal with the captain" ;;
    lcars:research)       echo "Stage: exploring the codebase and constraints" ;;
    lcars:validate)       echo "Stage: confirming research with the captain" ;;
    lcars:plan)           echo "Stage: drafting the implementation plan" ;;
    lcars:plan-review)    echo "Stage: captain reviewing the plan" ;;
    lcars:schedule)       echo "Stage: breaking the plan into tasks" ;;
    lcars:implement)      echo "Stage: executing the tasks" ;;
    lcars:verify)         echo "Stage: confirming the work meets the goal" ;;
    lcars:done)           echo "Stage: mission complete" ;;
    lcars:feature)        echo "Type: a feature mission" ;;
    lcars:bug)            echo "Type: a bug mission" ;;
    lcars:paused)         echo "Status: mission paused" ;;
    lcars:awaiting-human) echo "Status: waiting on the captain's orders" ;;
    lcars:linked)         echo "Relationship: linked to another mission" ;;
    lcars:mission)        echo "Role: a Mission's own command-and-control issue" ;;
    lcars:ticket)         echo "Role: an implementation sub-issue spun up by Schedule" ;;
    lcars:xo:high)        echo "Number One: intent match HIGH — the point of the mission and every requirement beyond polish worked" ;;
    lcars:xo:medium)      echo "Number One: intent match MEDIUM — the point of the mission works, with named known issues" ;;
    lcars:xo:low)         echo "Number One: intent match LOW — the point of the mission didn't work or couldn't be checked" ;;
    lcars:xo:engaged)     echo "Number One: engaged on this mission on the owner's behalf" ;;
    *)                    echo "LCARS label" ;;
  esac
}

# Emit every canonical "lcars:<name>|<color>" pair, one per line. Callers iterate
# this so the ordering/colours stay defined in exactly one place.
lcars_all_labels() {
  local n
  for n in $LCARS_STAGE_LABELS;  do echo "lcars:$n|$LCARS_STAGE_COLOR";  done
  for n in $LCARS_TYPE_LABELS;   do echo "lcars:$n|$LCARS_TYPE_COLOR";   done
  for n in $LCARS_STATUS_LABELS; do echo "lcars:$n|$LCARS_STATUS_COLOR"; done
  for n in $LCARS_REL_LABELS;    do echo "lcars:$n|$LCARS_REL_COLOR";    done
  for n in $LCARS_ROLE_LABELS;   do echo "lcars:$n|$LCARS_ROLE_COLOR";   done
  for n in $LCARS_XO_LABELS;     do echo "lcars:$n|$LCARS_XO_COLOR";     done
}

# lcars_create_labels — create any MISSING canonical labels on the current repo.
#
# Args:
#   $1  gh binary
#   $2  newline-separated list of labels already on the repo (may be empty)
#
# Sets these globals for the caller to report on:
#   LCARS_LABELS_CREATED   count created this run
#   LCARS_LABELS_SKIPPED   count already present (skipped)
#   LCARS_LABELS_CREATED_NAMES  space-separated names created
#
# A label already present is skipped (never re-created), so this is idempotent
# and shared identically by init and update.
lcars_create_labels() {
  local gh="$1" existing="$2"
  LCARS_LABELS_CREATED=0
  LCARS_LABELS_SKIPPED=0
  LCARS_LABELS_CREATED_NAMES=""

  local line name color
  while IFS='|' read -r name color; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$existing" | grep -Fxq "$name"; then
      LCARS_LABELS_SKIPPED=$((LCARS_LABELS_SKIPPED + 1))
      continue
    fi
    if "$gh" label create "$name" --color "$color" \
         --description "$(lcars_label_desc "$name")" >/dev/null 2>&1; then
      LCARS_LABELS_CREATED=$((LCARS_LABELS_CREATED + 1))
      LCARS_LABELS_CREATED_NAMES="${LCARS_LABELS_CREATED_NAMES:+$LCARS_LABELS_CREATED_NAMES }$name"
    else
      # Treat "already exists" races and other soft failures as skips.
      LCARS_LABELS_SKIPPED=$((LCARS_LABELS_SKIPPED + 1))
    fi
  done <<EOF
$(lcars_all_labels)
EOF
}

# ---------------------------------------------------------------------------
# FORGE HOST (GitHub Enterprise support)
# ---------------------------------------------------------------------------
# lcars_gh_web_host — the host to put in a link the captain will CLICK, derived
# from the repo's own origin remote. Falls back to github.com when there is no
# remote or it cannot be parsed, so a repo with no origin reads exactly as it
# always did.
#
# init/update used to print a hardcoded "on github.com/<owner>/<repo>", which on
# an enterprise repo links to a repository that does not exist. Unlike the
# adapter's gh_hostname (which returns EMPTY for github.com so the `gh api` argv
# stays byte-for-byte historic), this one ALWAYS yields a host — it is for
# display, where "github.com" is the right thing to actually print.
#
# LCARS_GH_HOST overrides, matching the adapter.
lcars_gh_web_host() {
  if [ -n "${LCARS_GH_HOST:-}" ]; then printf '%s' "$LCARS_GH_HOST"; return 0; fi
  local url h
  url="$("${LCARS_GIT_BIN:-git}" remote get-url origin 2>/dev/null)" \
    || { printf 'github.com'; return 0; }
  [ -n "$url" ] || { printf 'github.com'; return 0; }
  h="${url#*://}"    # drop scheme (https://, ssh://, git://)
  h="${h#*@}"        # drop user@ (scp-style git@host:owner/repo)
  h="${h%%/*}"       # drop the path
  h="${h%%:*}"       # drop :port, and the scp-style ":owner/repo"
  [ -n "$h" ] || h="github.com"
  printf '%s' "$h"
}

# ---------------------------------------------------------------------------
# ATTACHMENT WORDING — ONE RULE, EVERY SURFACE (S128 / FL-010)
# ---------------------------------------------------------------------------
# A Mission's durable attachments (S92) reach a worker through TWO different
# doors, and until now each door spelled the same sentence for itself:
#
#   • the cold-Stage PROMPT — `attachments_extra_block` in lcars-run/run.sh,
#     absolute paths, read by Research/Validate/Plan/Implement;
#   • the mission's own prd.md — written by lcars-file/file.sh (grill-first AND
#     --complete) and lcars-log/log.sh, relative paths. prd.md is ALSO the
#     GitHub issue body, so this is the document a human reads too.
#
# S127 taught the prompt door to name what actually arrived, because the
# holodeck hands a Mission a `mockup.html` + a `concept.md` down the SAME road
# pasted screenshots travel, and heading an HTML mockup "## Attached images" is
# a lie. It MISSED the other three copies — and the byte-exact suite guarding
# the one it fixed stayed green the whole time. Fixing a duplicated string in
# one of its homes and testing that home proves nothing about the others.
#
# So the wording lives HERE, once, and every door derives from it. The literal
# `## Attached images` appears in no other skill source; a fifth copy fails
# tests/lcars-run-attachments.test.sh the moment it is written.
#
# THE IMAGE-ONLY WORDING IS FROZEN. This is shared pipeline code and the
# overwhelming majority of missions are pasted screenshots; their prompt and
# their PRD must not move by one character. Both shapes assert it byte-for-byte.

# lcars_attach_kind <path> -> image | mockup | doc | other
# The single classification. Extension-only on purpose: these files were staged
# by LCARS itself under attachment-NN.<ext>, so the extension is the evidence.
lcars_attach_kind() {
  local ext=""
  case "$1" in *.*) ext="$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" ;; esac
  case "$ext" in
    png|jpg|jpeg|gif|webp|svg|bmp|heic) printf 'image' ;;
    html|htm)                           printf 'mockup' ;;
    md|markdown|txt|rst)                printf 'doc' ;;
    *)                                  printf 'other' ;;
  esac
}

# lcars_attach_all_images <paths...> -> exit 0 when every path is an image.
# THE frozen-wording switch. No args is NOT "all images" — there is nothing to
# head at all, and every caller guards on emptiness before asking.
lcars_attach_all_images() {
  [ "$#" -gt 0 ] || return 1
  local p
  for p in "$@"; do [ "$(lcars_attach_kind "$p")" = image ] || return 1; done
  return 0
}

# lcars_attach_heading <paths...> -> "## Attached images" | "## Attached files"
# The heading STEM only; each surface appends its own parenthetical, of which it
# has exactly one for both branches.
lcars_attach_heading() {
  if lcars_attach_all_images "$@"; then printf '## Attached images'
  else printf '## Attached files'; fi
}

# lcars_attach_tally <paths...> -> "1 image, 2 HTML mockups"
# What arrived, in plain English, in a fixed order so the sentence is stable.
lcars_attach_tally() {
  local p k n_img=0 n_mock=0 n_doc=0 n_other=0
  for p in "$@"; do
    k="$(lcars_attach_kind "$p")"
    case "$k" in
      image)  n_img=$((n_img + 1))   ;;
      mockup) n_mock=$((n_mock + 1)) ;;
      doc)    n_doc=$((n_doc + 1))   ;;
      *)      n_other=$((n_other + 1)) ;;
    esac
  done
  local what="" pair n noun
  for pair in "$n_img:image:images" "$n_mock:HTML mockup:HTML mockups" \
              "$n_doc:written document:written documents" \
              "$n_other:other file:other files"; do
    n="${pair%%:*}"
    [ "$n" -eq 0 ] && continue
    if [ "$n" -eq 1 ]; then
      noun="${pair#*:}"; noun="${noun%%:*}"
    else
      noun="${pair##*:}"
    fi
    [ -n "$what" ] && what="$what, "
    what="$what$n $noun"
  done
  printf '%s' "$what"
}

# lcars_attach_has_mockup <paths...> -> exit 0 when at least one is a mockup.
lcars_attach_has_mockup() {
  local p
  for p in "$@"; do [ "$(lcars_attach_kind "$p")" = mockup ] && return 0; done
  return 1
}

# lcars_attach_mockup_note -> the look-and-flow declaration, no trailing newline.
#
# It rides with the attachment list rather than living only in the PRD's prose
# on purpose: S164 measured a live worker correctly refusing a decoy because
# SEVERAL places it could not miss all said the same thing, and S166 measured a
# live worker ignoring the same claim made in ONE place.
#
# ⚠ THE LAST LINE IS PINNED TO THE DAEMON. `_HANDOFF_PRECEDENCE` in
# web/lcars_serve/actions.py is the AUTHORITY for that sentence — the daemon is
# the one voice that says it to the captain (the deck) and to the mission (the
# filed idea). This is bash and that is Python, so the literal cannot be shared;
# `tests/lcars-run-attachments.test.sh` section 10 reads the daemon's constant
# and pins this note's LAST LINE to it byte-for-byte instead. Reword one home
# without the other and that check fails naming both.
#
# It goes on ONE line, unwrapped, so the pin can be byte-exact. Do not re-wrap.
# S128/FL-011: it used to end "…the brief wins", which a live cold Research
# worker read as "the brief is EXHAUSTIVE" and used to discard a requirement the
# mockup carried and the brief had lost. The override survives; the completeness
# claim is denied in the same sentence so the two can never be separated.
# S169 fix round 1: the override is now SPLIT BY DOMAIN. A live drive produced a
# brief claiming the top bar was "kept" while the mockup in the same room had
# redrawn it, and the old sentence handed that false line the win. The brief is
# an ACCOUNT of a conversation and rules on WHAT IT MUST DO; the mockup is the
# artifact and rules on HOW IT LOOKS. See `_HANDOFF_PRECEDENCE` for the
# measurement — and reword BOTH homes or section 10 goes red naming both.
lcars_attach_mockup_note() {
  printf '%s' 'The HTML mockup is a VISUAL REFERENCE ONLY. It defines LOOK AND FLOW — layout,
colour, spacing, wording, and the transitions between screens — and matching it
visually is an acceptance criterion of this work. It is NOT an implementation:
its internals are deliberately fake, hand-written to look right and wired to
nothing. Do not import it, do not copy its internals as code, do not edit it to
change behaviour, and never ship it — it is not part of this repository'"'"'s
source and it is not a file this work may modify.
Where the mockup and the brief disagree about WHAT IT MUST DO, the brief OVERRIDES the mockup. That is a TIE-BREAK, not a claim that the brief is exhaustive — the brief can be missing something the mockup has. Where they disagree about HOW IT LOOKS, it is the other way round: the mockup is the authority and OVERRIDES the brief, including any line of the brief that says a thing was kept or left unchanged. The mockup IS the design; the brief is an ACCOUNT of the conversation that drew it, written afterwards, and an account can describe the picture wrongly.'
}

# lcars_attach_prd_section <relpaths...> -> the whole prd.md section, appended
# verbatim by lcars file (both lanes) and lcars log.
#
# Image-only output is BYTE-IDENTICAL to the pre-S128 string:
#     \n## Attached images\n\n- <rel>\n…
# No paths ⇒ nothing at all, so a mission without attachments is untouched.
lcars_attach_prd_section() {
  [ "$#" -gt 0 ] || return 0
  local rel
  if lcars_attach_all_images "$@"; then
    printf '\n## Attached images\n\n'
    for rel in "$@"; do printf -- '- %s\n' "$rel"; done
    return 0
  fi
  printf '\n%s\n\nWhat arrived: %s. Each is listed below by path relative to this mission'"'"'s directory.\n' \
    "$(lcars_attach_heading "$@")" "$(lcars_attach_tally "$@")"
  if lcars_attach_has_mockup "$@"; then
    printf '\n%s\n' "$(lcars_attach_mockup_note)"
  fi
  printf '\n'
  for rel in "$@"; do printf -- '- %s\n' "$rel"; done
}

# ---------------------------------------------------------------------------
# THE ANCHOR RULE (S237) — ONE text, ONE anchor extractor
# ---------------------------------------------------------------------------
# WHAT WENT WRONG. Over the weekend of 26–29 Sep 2026 a Plan Stage burned SIX
# failed attempts across TWO missions and then stopped dead, because the Plan
# prompt told the worker `drawnAt` was "your own words; there is no list of
# allowed anchors" while `validate_plan_json` REQUIRES a real element id from
# the drawing. The cure that worked FIRST TIME, by hand, was the captain
# pasting the rule verbatim WITH the actual anchor list into the PRD's
# Constraints.
#
# So the harness pastes it now, at BOTH ends — Align writes it into prd.md,
# Plan writes it into the assembled prompt — and the two ends read ONE file
# (lcars-run/stages/anchor-rule.md). Two copies of a rule that must agree is
# precisely the defect this cures one level up; do not add a second.
#
# The ANCHOR LIST is likewise single-sourced: lcars_mockup_place_names is the
# one extractor, and run.sh's mission_mockup_place_names delegates to it, so
# the list injected into the prompt is by construction the list the validator
# checks against. There is no second source of anchors in the harness.

# lcars_anchor_rule_file -> the path of the ONE rule-text source.
lcars_anchor_rule_file() {
  if [ -n "${LCARS_ANCHOR_RULE_FILE:-}" ]; then printf '%s' "$LCARS_ANCHOR_RULE_FILE"; return 0; fi
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || return 1
  printf '%s' "$d/../lcars-run/stages/anchor-rule.md"
}

# lcars_anchor_rule_line [space-separated-anchors] -> the rule, one line.
# With anchors: the ANCHORED form, @ANCHORS@ replaced by the comma-separated
# list. Without: the UNFENCED form (a drawing with no ids to cite hands over no
# list, because there is none to hand over). EMPTY and rc 1 when the source file
# is unreadable — every caller treats that as "inject nothing", never as a stop:
# a missing prompt paragraph must not be the thing that fails a filing.
lcars_anchor_rule_line() {
  local f; f="$(lcars_anchor_rule_file)" || return 1
  [ -r "$f" ] || return 1
  local want; want=anchored; [ -n "${1:-}" ] || want=unfenced
  local line
  line="$(awk -v want="$want" '
    $0 == "<!-- lcars:anchor-rule:" want " -->" { grab=1; next }
    grab && $0 == "<!-- lcars:anchor-rule:end -->" { exit }
    grab && NF { print; exit }
  ' "$f")"
  [ -n "$line" ] || return 1
  if [ "$want" = anchored ]; then
    local list; list="$(printf '%s' "$1" | tr -s ' ' '\n' | sed '/^$/d' | paste -sd, - | sed 's/,/, /g')"
    # No sed s///: an anchor id may legally contain `.` `:` `-`, and the list is
    # built from the drawing, so keep it out of a regex replacement entirely.
    printf '%s%s%s' "${line%%@ANCHORS@*}" "$list" "${line#*@ANCHORS@}"
  else
    printf '%s' "$line"
  fi
}

# lcars_mockup_place_names <paths...> -> space-separated, sorted, deduped
# element ids of every MOCKUP among these paths. EMPTY when there are none, or
# when the drawings carry no ids at all.
#
# Both quote styles; an id must look like an id (no spaces, starts with a
# letter) or it is markup noise, not a place a person can be pointed at.
# grep -o, not sed: a line legitimately carries SEVERAL ids
# (<section id="a"><div id="b">), and a greedy sed capture keeps only the LAST
# one — which silently shrinks the vocabulary and rejects honest anchors.
lcars_mockup_place_names() {
  local f names=""
  for f in "$@"; do
    [ -f "$f" ] || continue
    [ "$(lcars_attach_kind "$f")" = mockup ] || continue
    names="$names
$(grep -oE "[[:space:]]id=[\"'][^\"']*[\"']" "$f" \
   | sed -E "s/.*id=[\"']//; s/[\"']\$//" \
   | grep -E "^[A-Za-z][A-Za-z0-9_:.-]*$")"
  done
  printf '%s' "$(printf '%s' "$names" | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')"
}

# lcars_prd_inject_constraint <prd-path> <line> -> adds <line> as a bullet of
# the PRD's Constraints section, ONCE. IDEMPOTENT on the line's own leading
# token, so a PRD whose Constraints already carry the rule (the captain pasted
# it, an ECH injected it, or this ran before) never grows a second copy.
# Returns 0 whether or not it wrote: a PRD that cannot be read is left alone.
lcars_prd_inject_constraint() { # prd-path line
  [ -f "$1" ] || return 0
  [ -n "${2:-}" ] || return 0
  "${LCARS_PYTHON_BIN:-python3}" - "$1" "$2" <<'INJECT_PY' || return 0
import re, sys
path, line = sys.argv[1], sys.argv[2]
try:
    text = open(path).read()
except OSError:
    sys.exit(0)
# The idempotency KEY is the rule's own leading token, not the whole line: the
# anchor list changes when the drawing does, and a PRD carrying yesterday's
# list must not collect today's beside it.
key = line.split("(")[0].strip().rstrip(":") or line.strip()
lines = text.replace("\r\n", "\n").split("\n")
if any(key in l for l in lines):
    sys.exit(0)
# Both PRD shapes the harness accepts (see _lcars_prd_read): the bold inline
# label `**Constraints:**` and the heading `## Constraints`.
BOLD = re.compile(r"^\s*\**\s*Constraints\s*:?\s*\**\s*$", re.I)
INLINE = re.compile(r".*\*\*\s*Constraints\s*:\s*\*\*", re.I)
HEAD = re.compile(r"^\s{0,3}#{1,6}\s*Constraints\s*:?\s*$", re.I)
at = None
for i, l in enumerate(lines):
    if BOLD.match(l) or INLINE.match(l) or HEAD.match(l):
        at = i
        break
if at is None:
    # No Constraints section at all. Every lane that files a PRD gates on one
    # existing, so this is the hand-run / future-shape path: add the section
    # rather than silently dropping the rule.
    while lines and not lines[-1].strip():
        lines.pop()
    lines += ["", "## Constraints", "", "- " + line, ""]
else:
    lines.insert(at + 1, "- " + line)
open(path, "w").write("\n".join(lines))
INJECT_PY
  return 0
}

# ---------------------------------------------------------------------------
# BASE FRESHNESS (S158)
# ---------------------------------------------------------------------------
# A Mission filed off a base branch that is behind origin makes every downstream
# Stage reason about a tree that no longer exists. Observed 2026-07-30: a mission
# cut from a `main` 19 commits behind origin had Research truthfully report that a
# file "does not exist" — true of the stale tree, false of the deployed app — and
# the mission shipped 10 lines into a decoy.
#
# `ensure_base_current <base>` measures that base against origin BEFORE the
# Mission's branch is cut, brings it up to date when it safely can, and records an
# honest verdict either way. It ALWAYS returns 0 — a freshness check must never be
# the thing that stops a filing — and it is BEST-EFFORT: it declines to act in a
# dozen conditions, and in every one the Mission is still filed against whatever
# the captain has.
#
# THE CAPTAIN'S CLONE IS SACRED. It may fast-forward a clean, checked-out base and
# nothing else: never reset/force/stash/clean/switch/checkout, and never a write
# into a dirty tree. It DOES fetch on a dirty tree — a fetch writes only to
# refs/remotes/ — because "you are 19 behind" is a warning a captain acts on where
# "you might be behind" is one they dismiss.
#
# THE NETWORK HALF AND THE REF-MOVING HALF ARE SEPARATE, AND ONLY THE FIRST IS
# BOUNDED. A `git pull` is a fetch AND a checkout, so bounding it lets a kill land
# MID-CHECKOUT: a 1s bound against a commit adding 20,000 files wrote 8,455 of
# them into a tester's tree while the block said "nothing was pulled". So: (1) a
# narrow, bounded `git fetch` — killable, and provably unable to touch the working
# tree; then (2) an UNBOUNDED, local `git merge --ff-only <already-fetched sha>` —
# no network, and nothing that may kill it part-way. `--ff-only` is git's own
# refusal-by-default. Do not re-introduce LCARS_BASE_PULL_TIMEOUT_SECS: no
# ref-moving step is bounded any more, deliberately.
#
# THE VOCABULARY IS FOUR WORDS. It was fifteen — one name per situation, each with
# its own bespoke Why/Means/Fix prose — and across two captain-stand-in tester
# rounds EVERY defect was either a wrong git decision or copy that lied about one.
# The name count WAS the lying surface. The verdict now answers only the question
# a consumer acts on; the situation lives in ONE sentence beside it:
#
#   current   the base is up to date; nothing to do. This INCLUDES a base that is
#             merely AHEAD of origin (the everyday unpushed commit): the only
#             question this guard asks is whether the base is MISSING something
#             origin has, and an ahead-only base is missing nothing.
#   updated   LCARS brought it up to date; the mission is cut from the fresh tip.
#   stale     the base is behind and LCARS could NOT fix it — dirty tree, diverged
#             base, a fast-forward that would clobber an ignored file, a base that
#             is not checked out, a refused fast-forward, or an unpushed branch
#             behind the trunk it was cut from.
#   unknown   freshness could NOT be determined — no remote, unreachable, too slow
#             to wait for, no resolvable trunk, no such local branch, guard off,
#             or not a git repo at all.
#
# S159 ADDS EXACTLY ONE MORE, AND IT IS NOT A SHADE OF STALENESS:
#
#   child-base  the base is ANOTHER MISSION's branch, so the question does not
#               apply. A logged bug's base is its parent's `lcars/<parent-id>`
#               branch: "bring it up to date from origin" would mean moving the
#               fix onto code it was never written against — the exact "fix the
#               bug child by rebasing it onto main" hazard. The guard takes no
#               network call and moves no ref; it says so and stops.
#
# LOUDNESS IS CARRIED, NOT DERIVED: `unknown` covers both the silent everyday
# no-remote case and the loud unreachable one, so which outcomes shout is its own
# field, set with the verdict and never inferred from it. "Badge or no badge" is
# that one field.
#
# S160 ADDS ONE MODE, AND NO NEW NAMES. `LCARS_BASE_CHECK_ONLY=1` makes the guard
# ASK WITHOUT ANSWERING: it measures exactly as before and then declines the one
# step that writes — the local fast-forward in step 9. The board's File console
# runs this BEFORE the captain has typed a word, and a question whose asking
# fast-forwards the captain's checkout is not a question. Every lane a captain
# must ACT on already returns before step 9, so check-only changes the outcome of
# precisely one lane: the clean, fast-forwardable base, which reports `stale` and
# QUIETLY — filing is itself the fix there, and a warning whose only remedy is
# the action you were already taking is the trap S158 spent a round removing.
# `updated` therefore cannot be reached in this mode at all: that word means a
# ref moved, and nothing moved.
#
# Exported globals — the record a caller persists (see lcars_base_state_line):
#     LCARS_BASE_VERDICT      current | updated | stale | unknown
#     LCARS_BASE_LOUD         1 when this outcome prints the ⚠ block, else 0
#     LCARS_BASE_REASON       one sentence naming what actually happened
#     LCARS_BASE_FIX          ONE RUNNABLE COMMAND LINE, or NOTHING. Never prose,
#                             never two commands joined by the word "then", never
#                             a parenthetical. It is labelled `Fix:` on the CLI
#                             and on the board, and a tester who pastes it into a
#                             shell must get the condition cleared — not `bash:
#                             syntax error near unexpected token '('` (which is
#                             what `git stash -u   (or commit your work)   then
#                             git pull --ff-only origin main` really did, exit 2).
#                             When no command can succeed from here — an origin
#                             that has to come back first, a file the captain has
#                             to move themselves — this is EMPTY and the guidance
#                             lives in LCARS_BASE_FIXNOTE, which is never labelled
#                             as a command. S158 caught seven unrunnable fixes by
#                             executing them; the cure is that `fix` no longer has
#                             room for anything that is not a command.
#     LCARS_BASE_FIXNOTE      the prose that used to be smuggled into `fix` after
#                             three spaces: the alternative, the caveat, the
#                             manual step. Displayed beside the fix, never as one.
#     LCARS_BASE_BLOCKER      WHAT actually stopped LCARS from bringing the base
#                             up to date, as one short token (see the list below),
#                             or empty when nothing is blocking. It exists because
#                             a headline derived from `behindBy` names the benign
#                             half: "1 behind" is the state the captain was ruled
#                             safe to ignore, while the dirty tree that STOPPED
#                             the fast-forward showed up only in the body.
#                             CARRIED, NOT DERIVED — for the same reason `loud`
#                             is: a consumer re-deciding this from the reason
#                             prose is a second opinion that can disagree. It is
#                             written on the SAME call as the sentence that
#                             describes it, so the two cannot drift.
#     LCARS_BASE_BEHIND       commits origin has that the base does not, measured
#                             PRE-pull. EMPTY = NOT MEASURED, persisted as JSON
#                             `null`; `0` is reserved for a measured zero, because
#                             a reassuring 0 from a check that measured nothing is
#                             the one lie a consumer cannot detect.
#     LCARS_BASE_AHEAD        commits the base has that origin does not, same
#                             doctrine. Without it a consumer cannot tell "3
#                             behind and 2 ahead, genuinely diverged, act now"
#                             from "0 behind, 1 unpushed commit, perfectly fine".
#     LCARS_BASE_SHA          the base branch's sha AFTER the attempt — and
#                             NOTHING when there is no such branch. It never
#                             substitutes HEAD: a detached HEAD with no local
#                             `main` reported a real-looking sha for a branch that
#                             does not exist.
#     LCARS_BASE_CHECKED_AT   ISO stamp (honours $LCARS_NOW so callers can pin it)
#     LCARS_BASE_BRANCH       the base branch it was asked about
#     LCARS_BASE_TRUNK        origin's default branch, when one was resolved
#
# THE BLOCKER TOKENS, and there are no others. Each is a two-word summary of the
# ONE sentence it is written beside — it is not a second vocabulary competing
# with the verdict (S158's "the name count IS the lying surface" ruling), it is a
# handle on a sentence that already exists:
#
#   dirty-tree         the working tree has uncommitted work, and LCARS never
#                      writes into one
#   diverged           the base has commits origin does not AND is behind — no
#                      fast-forward exists
#   not-checked-out    HEAD is somewhere else, and LCARS will not check out a
#                      branch to move it
#   untracked-clobber  fast-forwarding would overwrite untracked local file(s)
#   merge-refused      git itself refused the purely local fast-forward
#   behind-trunk       an unpushed topic branch behind the trunk it was cut from;
#                      merging a trunk into it is a real merge, which is forbidden
#   unreachable        origin never answered, so nothing could be measured at all
#   fetch-timeout      origin ANSWERED a ref listing instantly, but the fetch ran
#                      past the bound LCARS is willing to make the captain wait,
#                      so nothing could be measured. A SEPARATE token from
#                      `unreachable` because they are separate situations: there
#                      the remote failed on its merits and no command run from
#                      this repo clears it (empty `fix`); here LCARS killed its
#                      OWN bounded fetch at its OWN deadline, and the captain's
#                      unbounded run of that same fetch really can succeed —
#                      which is exactly why this lane still carries one. Collapse
#                      the two and the badge tells a reachable origin it is
#                      unreachable while offering it a command.
#   operation-in-progress
#                      git itself is mid-operation here (an unfinished rebase,
#                      merge, cherry-pick, revert or bisect), so HEAD and the
#                      base ref are BOTH somewhere they will not stay
#
# S160 ROUND 2 — THE OPERATION LCARS ALREADY RAN IS NEVER THE FIX.
#
# A tester set `merge.verifySignatures=true`, filed, and pasted the offered fix.
# It answered `fatal: Commit 79ce589 does not have a GPG signature.` — BYTE-
# IDENTICAL to the failure LCARS had captured into its own `reason` one second
# earlier. The guard had run `git merge --ff-only <sha>`, watched git refuse it,
# quoted the refusal, and then offered THE SAME OPERATION as the remedy.
#
# The rule that closes it is general, not a `merge-refused` special case: when
# LCARS has ALREADY ATTEMPTED an operation and captured its failure, that same
# operation is never the `fix` — repeating it only reproduces the refusal.
#
# AND IT IS STRUCTURAL, because a rule that lives in a comment is a rule the next
# lane forgets. `_lcars_base_set_after_attempt` (below) is `_lcars_base_set` with
# the `fix` SLOT REMOVED, and every lane that reports a failed attempt records
# through it — so "attempted, failed, and offered anyway" is not a thing this
# file can express. Its mission-branch sibling is `_lcars_mb_refused_after_attempt`.
#
# ONE LANE IS DELIBERATELY NOT ONE OF THESE, and the boundary is worth naming:
# the BOUNDED fetch that times out (step 3) still offers `git fetch origin
# <base>`. Nothing refused that operation on its merits — LCARS killed its own
# fetch at its own deadline, and the captain's unbounded run of it is a
# different operation that really can succeed. The rule is about an operation
# that RAN TO COMPLETION AND WAS REFUSED, not one LCARS abandoned. That lane
# carries its own blocker token, `fetch-timeout`, for the same reason: the
# distinction between "the remote failed" and "LCARS gave up waiting" is
# load-bearing, and it is what decides whether a `fix` exists at all.

# The ONE consequence sentence, printed under every ⚠ block. It is a CONSTANT on
# purpose: the per-verdict `Means:` prose it replaces is exactly where the copy
# lied twice — a `no-base` block that talked about "your LOCAL main" when there
# was no local main, and a detached HEAD told it was filed against `main`. A
# sentence that does not vary cannot describe the wrong situation.
LCARS_BASE_IMPACT="a Stage reasons about the tree it is handed — an out-of-date one makes it confidently wrong about code that already exists."

# lcars_base_is_mission_branch <name> — is this branch name an LCARS MISSION
# branch rather than a trunk or topic branch?
#
# THE RULE IS THE `lcars/` NAMESPACE, and it is complete because LCARS mints
# mission branches in exactly ONE shape and nowhere else: `lcars/<mission-id>`
# (skills/lcars-file/file.sh `BRANCH="lcars/$ID"`, and skills/lcars-log/log.sh,
# which bases each bug child on its parent's branch — `lcars/<parent-id>` — or
# falls back to that literal name). Nothing else in LCARS creates a branch a
# Mission can be based on.
#
# Deliberately ONE rule, not two. A second, weaker heuristic (scan the missions
# on disk for one that claims this branch) would answer the same question a
# different way, and two answers is one more surface that can disagree — the
# S158 lesson about name count applies just as much to detection rules.
lcars_base_is_mission_branch() {
  case "${1:-}" in
    lcars/?*) return 0 ;;
    *)        return 1 ;;
  esac
}

# lcars_base_current_branch — the branch a Mission filed RIGHT NOW would be cut
# from: the checked-out branch, or the literal `main` when there isn't one.
#
# THIS IS A SHARED FUNCTION FOR ONE REASON. `lcars file` decides the base; the
# board's pre-flight check reports on the base. If those were two copies of the
# same three lines, the console could confidently describe the freshness of a
# branch the captain is not about to file against — a warning about the wrong
# thing, which is worse than no warning. One resolution, one answer.
#
# The `main` fallback is file.sh's own, kept verbatim: `rev-parse --abbrev-ref
# HEAD` answers the literal string "HEAD" on a detached HEAD (never empty), so
# both that and the empty answer fall back. It is a fallback, not a claim — when
# it is wrong, `ensure_base_current` says so loudly ("there is no local branch
# named 'main' to check").
lcars_base_current_branch() {
  local g b; g="$(_lcars_base_git)"
  b="$("$g" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$b" in ''|HEAD) b="main" ;; esac
  printf '%s' "$b"
}

# _lcars_base_git — the git binary, env-injected so tests can stub it.
_lcars_base_git() { printf '%s' "${LCARS_GIT_BIN:-${GIT_BIN:-git}}"; }

# _lcars_base_count <from> <to> — commits in from..to. EMPTY on any failure, so a
# caller can tell "not measured" from a measured zero.
_lcars_base_count() {
  local g c; g="$(_lcars_base_git)"
  c="$("$g" rev-list --count "$1..$2" 2>/dev/null)"
  case "$c" in ''|*[!0-9]*) c="" ;; esac
  printf '%s' "$c"
}

# THE RECORD IS ESCAPED BY `lcars_json_escape`, THE SIBLING IN THIS FILE — there
# is deliberately no bespoke escaper here any more. The one this section used to
# own stripped only \n\r\t and escaped only `\` and `"`, so every OTHER control
# byte went into state.json verbatim: a gitignored collider named
# `dist/ctl<0x01>name.txt` produced a record `python3 -m json.tool` refused
# ("Invalid control character at: line 9 column 282"). state.json is the record
# SKILL.md documents as consumable. `lcars file` writes it, S159's drive-time
# re-check (`cmd_drive` in skills/lcars-run/run.sh) both READS and REWRITES it,
# and S160's board badge (`LocalAdapter._card` in web/lcars_serve/) reads it to
# decide whether a Mission's card carries the ⚠ BASE pill. It must ALWAYS parse,
# whatever byte a captain happens to have in a filename. Round 4, D2.

# _lcars_base_visible <string> — make control characters VISIBLE, and touch
# NOTHING else. This is the DISPLAY escaper, and it is deliberately not
# `lcars_json_escape`: that one also escapes `\` and `"`, which would mangle the
# perfectly ordinary paths `build/back\slash.txt` and `build/quo"te.txt` in a
# warning the captain has to compare against their own `ls` output.
#
# It exists because a colliding path holding a NEWLINE was flattened to a space
# by `tr '\n' ' '`, so `dist/two\nline.txt` printed as `dist/two line.txt` —
# indistinguishable from a genuine space in a name, and from two separate files.
# The file was protected and named correctly; only the rendering was lossy.
_lcars_base_visible() {
  printf '%s' "${1:-}" | awk '
    BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
    { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
        if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
        else if (c=="\r") printf "\\r"
        else { b=index(MAP,c); if (b>0) printf "\\x%02x",b; else printf "%s",c } } }'
}

# _lcars_base_render_paths <newline-separated paths> — one space-joined list with
# every path in its own quotes. The quotes are the point: without a delimiter,
# `a b.txt` and the two files `a` + `b.txt` render identically.
#
# A path may contain the DELIMITER ITSELF, and that re-opened the very ambiguity
# the quoting exists to close: `dist/it's.txt` + `dist/plain.txt` came out as
# `'dist/it's.txt' 'dist/plain.txt'`, which reads just as well as `dist/it` +
# `s.txt'`. So an apostrophe is escaped the one way that is unambiguous inside
# single quotes — close, escape, re-open (`'it'\''s.txt'`) — which is also
# exactly what a shell would accept back. Nothing ELSE is touched: `\` and `"`
# stay verbatim (behaviour 33) so the captain can compare the warning against
# their own `ls`, and control characters are already made visible upstream by
# `_lcars_base_visible` (behaviour 41). Every check that DECIDES anything —
# `[ -e ]`, `ls-files`, `show | cmp` — still runs on the RAW path; this is
# display only. Round 5, D1.
_lcars_base_render_paths() {
  # bash 3.2 mangles a backslash-escaped apostrophe in a substitution's
  # replacement text (`${p//\'/\'\\\'\'}` yields `it\'\\'\'s`), so the delimiter
  # is carried in a variable and the replacement built from it.
  local out="" p q sq="'"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    q="${p//$sq/$sq\\$sq$sq}"
    [ -n "$out" ] && out="$out "
    out="$out'$q'"
  done <<EOF
${1:-}
EOF
  printf '%s' "$out"
}

# _lcars_base_run_bounded <secs> <outfile> <cmd…> — run a command with a HARD
# wall-clock bound, returning its status (or 124 on timeout). `lcars file` against
# a blackholed remote once printed NOTHING for 75 seconds; filing must never be
# held hostage by the network. `timeout(1)` is not reliably present on macOS, so
# this is run.sh's background-and-poll technique (perl setsid, so the whole process
# GROUP dies and no stray git is left running), copied rather than depended on.
#
# Three details are load-bearing. The poll-and-kill runs in a SUBSHELL with its
# own stderr on /dev/null, because bash reports a killed background job as
# "… line 248: 92631 Terminated: 15  perl -e …" — which reads like a crash and
# lands in whatever captures the CLI's output, the viewscreen daemon included (the
# command's own output is untouched: it goes to $outfile). The wait is a wall-clock
# deadline and the TERM→KILL grace is 0.2s, so "(up to Ns)" is a ceiling the code
# really honours. $SECONDS' 1s granularity can only make the kill land EARLY.
_lcars_base_run_bounded() {
  local secs="$1" outfile="$2"; shift 2
  case "$secs" in ''|*[!0-9]*) secs=8 ;; esac
  local rc=0
  (
    local pid t0="$SECONDS"
    if command -v perl >/dev/null 2>&1; then
      perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- "$@" >"$outfile" 2>&1 &
    else
      "$@" >"$outfile" 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$((SECONDS - t0))" -ge "$secs" ]; then
        kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        sleep 0.2 2>/dev/null || true
        kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 124
      fi
      sleep 0.2 2>/dev/null || sleep 1 2>/dev/null || true
    done
    wait "$pid"; exit $?
  ) 2>/dev/null
  rc=$?
  return "$rc"
}

# _lcars_base_fetch_secs — the ONE bound, overridable. It covers each bounded
# NETWORK call; the fast-forward that follows is local and unbounded.
#
# It SANITISES exactly as `_lcars_base_run_bounded` does, and that is the whole
# point of it existing rather than reading the env var inline: the announcement
# and the runner must never be able to disagree. `LCARS_BASE_FETCH_TIMEOUT_SECS=abc`
# printed "(up to abcs)…" over a call the runner had quietly clamped to 8 — an
# announced bound that is not the bound is a lie the captain has no way to catch.
# Round 4, D3.
_lcars_base_fetch_secs() {
  local s="${LCARS_BASE_FETCH_TIMEOUT_SECS:-8}"
  case "$s" in ''|*[!0-9]*) s=8 ;; esac
  printf '%s' "$s"
}

# _lcars_base_envp — populate LCARS_BASE_ENVP, the argv prefix that makes git
# INCAPABLE of stopping to ask a human anything. Without it, a machine with no
# cached credentials pops a bare `Username for 'https://github.com':` in the
# middle of a filing, with no context at all. It is an ARRAY (not a string)
# because GIT_SSH_COMMAND legitimately contains spaces.
_lcars_base_envp() {
  LCARS_BASE_ENVP=(env
    GIT_TERMINAL_PROMPT=0
    GIT_ASKPASS=echo
    SSH_ASKPASS=echo
    "GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes")
}

# _lcars_base_announce <what> — one legible line BEFORE EACH bounded network
# call, so a slow remote reads as a slow remote and not as a hang. Every bounded
# call announces itself, so the stated bound is the truth about the call the
# captain is waiting on rather than about only the first of several.
#
# IT GOES TO STDERR, AND THAT IS THE POINT (S160 round 3, D3). This is PROGRESS,
# not the verdict: `base-freshness.sh --line` documents its stdout as "the human
# ⚠ block, EMPTY when all is well", and on a clean, current repo the only thing
# on stdout was this ⟳ line — so a consumer testing emptiness read "all is well"
# as "something to say". On stderr the captain waiting at an interactive prompt
# still sees it (both fds land on the same terminal), while stdout carries the
# verdict and nothing else. It also puts the line out of reach of a `$(…)`
# capture, the failure mode the trunk resolver's own comment describes below.
_lcars_base_announce() {
  [ "${LCARS_BASE_QUIET:-0}" = "1" ] && return 0
  printf '  ⟳ base freshness — %s (up to %ss)…\n' "$1" "$(_lcars_base_fetch_secs)" >&2
  return 0
}

# _lcars_base_fetch_ref <branch> — a NARROW, tagless, bounded fetch of exactly ONE
# branch into its own remote-tracking ref. Returns git's status (124 on timeout).
# A bare `git fetch origin` turned a tester's clone from 2 remote-tracking refs and
# 0 tags into 62 refs and 1 tag after a SINGLE `lcars file`: not destructive, but a
# filing command has no business restructuring the captain's remote refs, and on a
# monorepo a whole-remote fetch is the likeliest way to blow the bound and
# manufacture a false `unknown`. The trunk, when needed, is fetched just as
# narrowly.
_lcars_base_fetch_ref() {
  local g rc=0; g="$(_lcars_base_git)"
  [ -n "${1:-}" ] || return 1
  _lcars_base_envp
  _lcars_base_announce "fetching origin/$1"
  _lcars_base_run_bounded "$(_lcars_base_fetch_secs)" /dev/null \
    "${LCARS_BASE_ENVP[@]}" "$g" fetch --no-tags --quiet origin \
    "+refs/heads/$1:refs/remotes/origin/$1" || rc=$?
  return "$rc"
}

# _lcars_base_probe [branch] — ask origin ONE bounded, read-only question:
# `ls-remote --symref origin HEAD [refs/heads/<branch>]`. It answers two things a
# failed fetch cannot distinguish on its own:
#   • is origin ALIVE? (a fetch that ran out of its bound against a remote that
#     answers instantly is SLOW, not unreachable, and saying "LCARS could not
#     reach origin" about it is simply false)
#   • does origin have a branch by that name at all? (the everyday unpushed topic
#     branch, which must not read as a failure)
# Sets LCARS_BASE_PROBE_RC (0 = origin answered), LCARS_BASE_PROBE_TRUNK (origin's
# default branch, when HEAD resolves) and LCARS_BASE_PROBE_HASBASE (0 = yes).
_lcars_base_probe() {
  local g out rc=0 ref="${1:-}"; g="$(_lcars_base_git)"
  LCARS_BASE_PROBE_TRUNK=""; LCARS_BASE_PROBE_HASBASE=1; LCARS_BASE_PROBE_RC=1
  out="$(mktemp 2>/dev/null)" || return 0
  _lcars_base_envp
  _lcars_base_announce "asking origin what it has"
  if [ -n "$ref" ]; then
    _lcars_base_run_bounded "$(_lcars_base_fetch_secs)" "$out" \
      "${LCARS_BASE_ENVP[@]}" "$g" ls-remote --symref origin HEAD "refs/heads/$ref" || rc=$?
  else
    _lcars_base_run_bounded "$(_lcars_base_fetch_secs)" "$out" \
      "${LCARS_BASE_ENVP[@]}" "$g" ls-remote --symref origin HEAD || rc=$?
  fi
  LCARS_BASE_PROBE_RC="$rc"
  if [ "$rc" -eq 0 ]; then
    LCARS_BASE_PROBE_TRUNK="$(sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]].*|\1|p' "$out" 2>/dev/null | head -1)"
    if [ -n "$ref" ]; then
      awk -v r="refs/heads/$ref" '$2==r { found=1 } END { exit found?0:1 }' "$out" 2>/dev/null \
        && LCARS_BASE_PROBE_HASBASE=0
    fi
  fi
  rm -f "$out"
  return 0
}

# _lcars_base_resolve_trunk [hint] — resolve origin's DEFAULT branch name into
# LCARS_BASE_TRUNK_NAME (empty when it cannot be resolved honestly). A hint from a
# probe that already ran wins, so the trunk never costs a second network call;
# otherwise refs/remotes/origin/HEAD (present in every real clone), and only if
# that is missing is origin asked. It answers in a VARIABLE, never on stdout,
# because it may make a network call and every network call ANNOUNCES itself —
# inside a `$(…)` that announcement gets captured as part of the trunk NAME, and
# a real drive printed `⟳ … fetching origin/  ⟳ … asking origin what it has…`.
_lcars_base_resolve_trunk() {
  local g ref hint="${1:-}" probed="${2:-0}"; g="$(_lcars_base_git)"
  LCARS_BASE_TRUNK_NAME=""
  if [ -n "$hint" ]; then LCARS_BASE_TRUNK_NAME="$hint"; return 0; fi
  ref="$("$g" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
  if [ -n "$ref" ]; then LCARS_BASE_TRUNK_NAME="${ref#origin/}"; return 0; fi
  # A probe that already ran asked for `--symref HEAD` too, so if it came back
  # without a trunk, asking again cannot produce one — and the empty-remote path
  # really did print "asking origin what it has" twice, under a comment claiming
  # the trunk "never costs a second network call".
  [ "$probed" = "1" ] && return 0
  _lcars_base_probe ""
  LCARS_BASE_TRUNK_NAME="${LCARS_BASE_PROBE_TRUNK:-}"
  return 0
}

# _lcars_base_clobber_paths <from-sha> <to-sha> — paths the incoming commits add
# that ALREADY EXIST locally as files git is not tracking (untracked or, the
# dangerous case, gitignored). `git status --porcelain` reads CLEAN with a
# gitignored `dist/bundle.js` sitting there, so without this check an
# LCARS-initiated fast-forward silently destroys a file the captain never asked
# anyone to touch. A file whose local content is BYTE-IDENTICAL to the incoming
# one has nothing to lose, so refusing over it would warn about a harm that
# cannot happen — compare, and let it through.
#
# THE ENUMERATION IS NUL-SEPARATED, AND THAT IS LOAD-BEARING. `core.quotePath` is
# git's DEFAULT, so plain `--name-only` C-QUOTES any path holding a non-ASCII
# byte, a `"` or a `\` — `"build/caf\303\251.txt"` — and the literal quoted
# string fails `[ -e ]`, so the collider was silently DROPPED and the pull went
# through with a ✓ over the captain's file. With a mixed set only the ASCII
# sibling was named, so obeying the printed fix and re-filing destroyed the rest.
# `-z` applies no quoting or escaping at all (and survives newlines in names too),
# where `-c core.quotePath=false` would still escape `"` and `\`.
#
# It EMITS one path per line with control characters made visible
# (`_lcars_base_visible`), which is what makes "one line = one path" true even for
# a name that contains a newline. Every check above it — `[ -e ]`, `ls-files`,
# `show | cmp` — runs against the RAW byte-for-byte path; only the OUTPUT is
# rendered. Round 4, D2 (smell).
_lcars_base_clobber_paths() {
  local g root; g="$(_lcars_base_git)"
  root="$("$g" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$root" ] || return 0
  (
    cd "$root" 2>/dev/null || exit 0
    "$g" diff --name-only -z "$1" "$2" 2>/dev/null | while IFS= read -r -d '' p; do
      [ -n "$p" ] || continue
      [ -e "$p" ] || continue
      "$g" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && continue
      if [ -f "$p" ] && "$g" show "$2:$p" 2>/dev/null | cmp -s - "$p" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$(_lcars_base_visible "$p")"
    done
  )
}

# _lcars_base_dirt <porcelain> — describe what `git status --porcelain` is
# ACTUALLY showing, and pick a stash that would actually move it. Untracked-only
# dirt was once reported as "N uncommitted change(s)" with the fix `git stash` —
# which does not touch untracked files at all, so the captain ran it, was told
# "No local changes to save", and got nowhere. The copy must match the KIND of
# dirt. Sets LCARS_BASE_DIRT_DESC and LCARS_BASE_DIRT_STASH.
_lcars_base_dirt() {
  local porc="$1" line x y staged=0 unstaged=0 untracked=0 parts=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '??'*) untracked=$((untracked + 1)); continue ;;
    esac
    x="${line:0:1}"; y="${line:1:1}"
    [ -n "$x" ] && [ "$x" != " " ] && staged=$((staged + 1))
    [ -n "$y" ] && [ "$y" != " " ] && unstaged=$((unstaged + 1))
  done <<EOF
$porc
EOF
  [ "$staged"    -gt 0 ] && parts="$staged staged change(s)"
  if [ "$unstaged" -gt 0 ]; then
    [ -n "$parts" ] && parts="$parts and "
    parts="$parts$unstaged unstaged change(s)"
  fi
  if [ "$untracked" -gt 0 ]; then
    [ -n "$parts" ] && parts="$parts and "
    parts="$parts$untracked untracked file(s)"
  fi
  [ -n "$parts" ] || parts="uncommitted change(s)"
  LCARS_BASE_DIRT_DESC="$parts"
  # `git stash` leaves untracked files exactly where they are; -u is the only
  # form that moves them. Naming the wrong one is what made the old fix a no-op.
  if [ "$untracked" -gt 0 ]; then
    LCARS_BASE_DIRT_STASH="git stash -u"
  else
    LCARS_BASE_DIRT_STASH="git stash"
  fi
  return 0
}

# _lcars_base_dirty_fix <base> — the ONE runnable line that clears a dirty tree
# blocking a fast-forward: stash (the form `_lcars_base_dirt` chose) AND THEN
# pull. `&&` because it must survive being pasted verbatim; the old string joined
# the two with the English word "then" and a parenthetical alternative, which a
# tester pasted into bash and got `syntax error near unexpected token '('`,
# exit 2. The alternative ("or commit your work") is real advice and still
# shipped — as LCARS_BASE_FIXNOTE, which nothing labels `Fix:`.
_lcars_base_dirty_fix() {
  printf '%s && git pull --ff-only origin %s' \
    "${LCARS_BASE_DIRT_STASH:-git stash}" "${1:-main}"
}

# The note that rides with it, everywhere the dirty-tree fix appears.
LCARS_BASE_DIRT_NOTE="You can commit your work instead of stashing — either clears the block; 'git stash pop' brings a stash back afterwards."

# ---------------------------------------------------------------------------
# AN UNFINISHED GIT OPERATION (S160 round 2, D2)
# ---------------------------------------------------------------------------
# THE DEFECT. A tester pasted the `diverged` fix (`git pull --rebase origin
# main`), hit a conflict — the COMMON outcome for a diverged branch — and filed
# from there. The record LCARS stamped said `stale`, "a fast-forward is
# impossible, so nothing was moved", and named `baseSha: 1d12dd5` while the
# Mission's branch was cut from 79ce589. Every one of those is a statement about
# a repo that was mid-surgery: HEAD detached, `README.md` unmerged,
# `.git/rebase-merge` sitting right there. It re-offered the same rebase, which
# now `fatal`s ("there is already a rebase-merge directory"), and the MISSION
# BRANCH block raised a "1 commit behind" alarm the graph disproved.
#
# AN UNFINISHED OPERATION IS THE SINGLE MOST IMPORTANT FACT ABOUT A REPO, and
# every number measured around it is a measurement of a transient: `refs/heads/
# <base>` is where the rebase will move it FROM, not where it will end up, and
# HEAD is a replay position that exists for the next few seconds. So the guard
# detects it FIRST, takes no network call, measures nothing, moves nothing, and
# says plainly what git is in the middle of. Filing is still never blocked.
#
# `git rev-parse --git-path`, NEVER "$PWD/.git/<name>". A LINKED WORKTREE's git
# dir is `<main>/.git/worktrees/<name>/`, so a rebase started in one of LCARS's
# own mission worktrees leaves `…/worktrees/<name>/rebase-merge` and a hard-coded
# `.git/` check is blind to exactly the trees LCARS creates. `--git-path` answers
# correctly from a subdirectory and from a linked worktree alike — asked, never
# assumed. (It is also why this cannot be a `[ -e .git/… ]` one-liner: see the
# S158 `core.quotePath` lesson about path checks that silently never fire.)
#
# Sets LCARS_BASE_INFLIGHT to the operation's name, or EMPTY when none is in
# progress; and LCARS_BASE_INFLIGHT_UNMERGED to the count of unmerged paths.
_lcars_base_inflight() {
  local g p
  g="$(_lcars_base_git)"
  LCARS_BASE_INFLIGHT=""
  LCARS_BASE_INFLIGHT_UNMERGED=0
  # Order is by how much it changes what the repo IS: a rebase/merge/cherry-pick
  # /revert has a pending commit to land, a bisect merely parks HEAD somewhere
  # old — but that "somewhere old" is what a Mission would be cut from, so it
  # counts too. `rebase-merge` and `rebase-apply` are the two rebase backends.
  for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    if [ -e "$("$g" rev-parse --git-path "$p" 2>/dev/null)" ]; then
      case "$p" in
        rebase-merge) LCARS_BASE_INFLIGHT="rebase" ;;
        rebase-apply)
          # `git am` and a rebase on the apply backend SHARE this directory, and
          # they do not share their commands: telling an `am` captain to run
          # `git rebase --continue` is the copy-that-lies-about-git class this
          # round is closing. `applying` is git's own marker for the am case.
          if [ -e "$("$g" rev-parse --git-path rebase-apply/applying 2>/dev/null)" ]; then
            LCARS_BASE_INFLIGHT="am"
          else
            LCARS_BASE_INFLIGHT="rebase"
          fi ;;
        MERGE_HEAD)       LCARS_BASE_INFLIGHT="merge" ;;
        CHERRY_PICK_HEAD) LCARS_BASE_INFLIGHT="cherry-pick" ;;
        REVERT_HEAD)      LCARS_BASE_INFLIGHT="revert" ;;
        BISECT_LOG)       LCARS_BASE_INFLIGHT="bisect" ;;
      esac
      break
    fi
  done
  [ -n "$LCARS_BASE_INFLIGHT" ] || return 0
  # Count only — never a path test, so `core.quotePath`'s C-quoting cannot make
  # this quietly answer "none" (the S158 gotcha that defeated a `[ -e ]` check).
  local n
  n="$("$g" diff --name-only --diff-filter=U 2>/dev/null | grep -c . )"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  LCARS_BASE_INFLIGHT_UNMERGED="$n"
  return 0
}

# _lcars_base_inflight_note <operation> — the guidance beside an unfinished
# operation. Only the bisect lane gets a `fix`, and the split is the fix
# contract, not squeamishness: `git bisect reset` is ONE runnable line that
# really does clear the condition and loses no work. Finishing a conflicted
# rebase/merge/cherry-pick/revert is NOT one command — the conflict has to be
# resolved by hand first, `--continue` errors while paths are unmerged, and
# `--abort` throws away resolution work already done. LCARS cannot know which
# the captain wants, so it names both and offers neither as `Fix:`.
_lcars_base_inflight_note() {
  case "$1" in
    bisect)
      printf 'that ends the bisect and puts HEAD back on the branch you started it from; nothing in your working tree is lost. Finish bisecting first if you are mid-hunt.' ;;
    rebase)
      printf "only you can decide how this ends: resolve the conflicted path(s), 'git add' them and 'git rebase --continue', or 'git rebase --abort' to put the branch back exactly where it started. Either one clears this." ;;
    merge)
      printf "only you can decide how this ends: resolve the conflicted path(s), 'git add' them and 'git merge --continue', or 'git merge --abort' to put the branch back exactly where it started. Either one clears this." ;;
    *)
      printf "only you can decide how this ends: resolve the conflicted path(s), 'git add' them and 'git %s --continue', or 'git %s --abort' to put the branch back exactly where it started. Either one clears this." "$1" "$1" ;;
  esac
}

# _lcars_base_set <verdict> <loud> <reason> [fix] [blocker] [note] — record the
# outcome + resolve the base's post-attempt sha. Deliberately does NOT touch
# LCARS_BASE_BEHIND / LCARS_BASE_AHEAD, which callers set before calling when
# they measured them.
#
# `blocker` and `note` are positional on THIS call on purpose. They could have
# been assignments the lanes make on their own lines, but then a lane could set a
# blocker that describes a different sentence from the one it passes here, and a
# headline that contradicts its own body is exactly the failure they exist to
# fix. Passed here, they are written in the same breath as the reason, and
# UNSET when a lane does not pass them — a lane that forgets says nothing rather
# than inheriting the previous lane's words.
#
# `baseSha` is the BASE BRANCH's sha or NOTHING. It used to fall back to HEAD,
# which meant a detached HEAD with no local `main` recorded a real-looking sha for
# a branch that does not exist, and a consumer reading it believed local `main`
# sat there. That is the same substitution `behindBy` refuses when it reports
# `null` rather than a reassuring `0` — an invented value a consumer cannot
# detect. No base branch, no sha.
_lcars_base_set() {
  local g; g="$(_lcars_base_git)"
  LCARS_BASE_VERDICT="$1"
  LCARS_BASE_LOUD="$2"
  LCARS_BASE_REASON="$3"
  LCARS_BASE_FIX="${4:-}"
  LCARS_BASE_BLOCKER="${5:-}"
  LCARS_BASE_FIXNOTE="${6:-}"
  LCARS_BASE_SHA="$("$g" rev-parse --verify -q "refs/heads/$LCARS_BASE_BRANCH" 2>/dev/null)" || LCARS_BASE_SHA=""
  return 0
}

# _lcars_base_set_after_attempt <verdict> <loud> <reason> [blocker] [note] — the
# recorder for an outcome LCARS reached BY TRYING AND FAILING.
#
# It is `_lcars_base_set` WITH THE `fix` SLOT REMOVED, and the removal IS the
# feature. See "THE OPERATION LCARS ALREADY RAN IS NEVER THE FIX" at the top of
# this file: a lane that ran `git merge --ff-only`, watched git refuse it and
# quoted the refusal used to offer that same merge back as the remedy, and a
# tester pasted it and got the identical `fatal:` a second time. Making the rule
# a comment beside each lane is what let it happen once already (two other lanes
# carry that comment and honour it); making the recorder for this SITUATION
# incapable of carrying a command means no future lane can get it wrong.
#
# The guidance still ships — as `note`, which nothing anywhere labels `Fix:`.
_lcars_base_set_after_attempt() {
  _lcars_base_set "$1" "$2" "$3" "" "${4:-}" "${5:-}"
}

# _lcars_mb_refused_after_attempt <reason> [note] — the same rule, for the
# MISSION BRANCH record. `lcars_base_advance_mission_branch` really runs `git
# branch -f` / `git merge --ff-only` and sometimes watches git refuse them; those
# lanes get a reason and NO fix, by construction rather than by remembering to.
#
# AND A WAY FORWARD, ALSO BY CONSTRUCTION (S160 round 3, D1). Removing the `fix`
# slot removed the wrong answer and left NO answer: a tester on the checked-out
# merge-refused lane read `Why:` / `Means:` / `Impact:` and nothing else — an
# honest diagnosis with no hint that clearing git's objection is theirs to do.
# The base's own sibling lane (step 9) has carried those words as a `fixNote`
# since round 2; here the recorder WRITES them, so a lane cannot ship the dead
# end by omission. A lane with better words passes its own; none can pass none.
_lcars_mb_refused_after_attempt() {
  local note="${2:-}"
  # Deliberately does not name the operation: which one git refused is already in
  # the reason, in git's own words, and a note that guesses at it is a second
  # account that can disagree with the first.
  [ -n "$note" ] || note="git refused this itself, so there is no command LCARS can offer: running the same operation again only repeats the refusal. Clear whatever git objected to — its own words are in the reason above — and the branch fast-forwards on the next drive."
  LCARS_MB_MOVE="refused"
  LCARS_MB_REASON="$1"
  LCARS_MB_FIX=""
  LCARS_MB_NOTE="$note"
  return 0
}

# lcars_base_report — say one legible thing about the outcome. A quiet outcome says
# NOTHING (a local-only or already-current repo must read exactly as it did before
# this guard existed); `updated` gets one ✓ line; a LOUD one gets the block.
# LCARS_BASE_QUIET=1 silences all of it. The ✓ line claims only what this function
# can know — that the BASE moved. Whether the MISSION sits on it is a different
# fact, owned by lcars_base_branch_note: with a leftover `lcars/<id>` at an old sha
# the two are opposites, and printing both claims side by side was a lie.
lcars_base_report() {
  [ "${LCARS_BASE_QUIET:-0}" = "1" ] && return 0
  [ -n "${LCARS_BASE_VERDICT:-}" ] || return 0
  if [ "${LCARS_BASE_LOUD:-0}" != "1" ]; then
    [ "$LCARS_BASE_VERDICT" = "updated" ] && \
      printf '  ✓ base %s fast-forwarded %s commit(s) from origin.\n' \
        "$LCARS_BASE_BRANCH" "${LCARS_BASE_BEHIND:-?}"
    # S159 — a skipped check still says it skipped. `child-base` is not a warning
    # (it is the CORRECT state for every logged bug), so it gets one quiet line
    # rather than the ⚠ block: silence here would read as "checked, all fine",
    # which is a different claim from "did not check, and here is why".
    [ "$LCARS_BASE_VERDICT" = "child-base" ] && \
      printf '  ⊘ base %s is a Mission branch — left exactly as it is (nothing fetched, nothing moved).\n' \
        "$LCARS_BASE_BRANCH"
    return 0
  fi
  printf '\n'
  if [ "$LCARS_BASE_VERDICT" = "stale" ]; then
    printf "  ⚠ BASE FRESHNESS — '%s' is out of date and LCARS could not fix it [%s]\n" \
      "$LCARS_BASE_BRANCH" "$LCARS_BASE_VERDICT"
  elif [ -z "${LCARS_BASE_SHA:-}" ] \
    && ! "$(_lcars_base_git)" rev-parse --verify -q "refs/heads/$LCARS_BASE_BRANCH" >/dev/null 2>&1; then
    # There IS no branch by that name. `file.sh` falls back to the literal string
    # `main` for a detached HEAD, so in a `master`-only repo the old header asked
    # whether 'main' was out of date — a question about a branch that exists
    # nowhere. The header must not assert the thing the reason is about to deny.
    printf "  ⚠ BASE FRESHNESS — there is no local branch named '%s' to check [%s]\n" \
      "$LCARS_BASE_BRANCH" "$LCARS_BASE_VERDICT"
  else
    printf "  ⚠ BASE FRESHNESS — LCARS could not tell whether '%s' is out of date [%s]\n" \
      "$LCARS_BASE_BRANCH" "$LCARS_BASE_VERDICT"
  fi
  printf '    Why:    %s\n' "$LCARS_BASE_REASON"
  # `Fix:` labels a COMMAND and nothing else — one line, pasteable verbatim. The
  # prose that used to ride along after three spaces gets its own `Note:` row, so
  # a captain who copies the Fix line copies something that runs.
  [ -n "${LCARS_BASE_FIX:-}" ] && printf '    Fix:    %s\n' "$LCARS_BASE_FIX"
  [ -n "${LCARS_BASE_FIXNOTE:-}" ] && printf '    Note:   %s\n' "$LCARS_BASE_FIXNOTE"
  printf '    Impact: %s\n' "$LCARS_BASE_IMPACT"
  printf '\n'
  return 0
}

# lcars_base_branch_note [mission-branch] [base] [how] — the truth about the
# MISSION's OWN branch: is it sitting on the base this check just judged? Two
# places need it — filing, where a leftover `lcars/<id>` at an old sha must not be
# papered over by the base's ✓ line, and `--complete`, where the branch was cut at
# park time and the base has since moved (it must NOT be re-cut, so say so with the
# command that fixes it). `how` is `reused` or `new`, because hard-coding "already
# existed at <sha>" is a flat untruth about a branch this filing just created from
# a detached HEAD; an empty `how` claims neither.
lcars_base_branch_note() {
  [ "${LCARS_BASE_QUIET:-0}" = "1" ] && return 0
  local g mb="${1:-}" base="${2:-${LCARS_BASE_BRANCH:-}}" how="${3:-}" tip basesha behind ahead tipshort hb origintip missing
  g="$(_lcars_base_git)"
  [ -n "$mb" ] && [ -n "$base" ] || return 0
  tip="$("$g" rev-parse --verify -q "refs/heads/$mb" 2>/dev/null)" || tip=""
  basesha="$("$g" rev-parse --verify -q "refs/heads/$base" 2>/dev/null)" || basesha=""
  # No branch yet (an empty repo) or no local base: the caller's own warnings
  # already cover those, and inventing a second one would just add noise.
  [ -n "$tip" ] && [ -n "$basesha" ] || return 0
  behind="$(_lcars_base_count "$tip" "$basesha")"
  if [ "${behind:-0}" = "0" ]; then
    # The mission branch DOES contain the base tip. Only say so when something
    # actually moved — an already-current repo stays silent, as it always has.
    [ "${LCARS_BASE_VERDICT:-}" = "updated" ] \
      && printf '  ✓ %s is cut from the CURRENT tree.\n' "$mb"
    return 0
  fi
  # THE ALARM MUST SURVIVE THE GRAPH (S160 round 2, D2). A tester's mission
  # branch sat EXACTLY on origin/main — behind 0, ahead 0, the freshest base
  # there is — and this block still shouted "is 1 commit(s) behind main" and
  # "will reason about that older tree", because local `main` had diverged and
  # carried a commit of its own. Permanently written, and false.
  #
  # So ask the mission branch the SAME question the whole guard asks the base:
  # is it MISSING something ORIGIN has? (step 5a: an ahead-only base is
  # `current`, because missing nothing is the entire test.) Measured, never
  # assumed — `_lcars_base_count` is right here. If origin/<base> is not known
  # locally there is nothing to measure against and the old ⚠ stands unchanged.
  origintip="$("$g" rev-parse --verify -q "refs/remotes/origin/$base" 2>/dev/null)" || origintip=""
  if [ -n "$origintip" ]; then
    missing="$(_lcars_base_count "$tip" "$origintip")"
    if [ "${missing:-x}" = "0" ]; then
      # It contains everything the rest of the world can see. That is not a
      # warning — but it is not silence either: it IS behind the local base, and
      # a captain who put commits on `$base` deliberately should read that here.
      printf "  ✓ %s is %s commit(s) behind local '%s', but contains everything on origin/%s — no Stage will read an older shared tree.\n" \
        "$mb" "$behind" "$base" "$base"
      return 0
    fi
  fi
  ahead="$(_lcars_base_count "$basesha" "$tip")"
  tipshort="$("$g" rev-parse --short "$tip" 2>/dev/null)"
  # The branch HEAD is on right now — empty when detached. Two things need it:
  # the `new` Why: line, and the way back offered under the rebase fix.
  hb="$("$g" symbolic-ref -q --short HEAD 2>/dev/null)" || hb=""
  printf '\n'
  printf '  ⚠ MISSION BRANCH — %s is %s commit(s) behind %s\n' "$mb" "$behind" "$base"
  case "$how" in
    new)
      # Name the commit the mission branch is REALLY on, once — a detached HEAD's
      # description already IS that sha, so repeating it read as a stutter.
      if [ -n "$hb" ]; then
        printf "    Why:    %s was cut by this filing from '%s', at %s — LCARS cuts a mission\n" "$mb" "$hb" "$tipshort"
      else
        printf '    Why:    %s was cut by this filing from the detached commit %s — LCARS cuts a\n' "$mb" "$tipshort"
      fi
      printf '            mission branch from HEAD, and never moves your HEAD to do it.\n'
      ;;
    reused)
      printf '    Why:    %s already existed at %s, and LCARS never moves a branch that\n' "$mb" "$tipshort"
      printf '            may already carry work — so it was reused exactly as it was.\n'
      ;;
    *)
      printf '    Why:    %s sits at %s, and LCARS never moves a branch that may already\n' "$mb" "$tipshort"
      printf '            carry work — so it was left exactly as it was.\n'
      ;;
  esac
  printf '    Means:  this mission does NOT contain the latest %s commit(s) on %s. Every\n' "$behind" "$base"
  printf '            Stage works from %s, so they will reason about that older tree.\n' "$mb"
  if [ "${ahead:-0}" = "0" ]; then
    # A pure fast-forward of the pointer: no commit can be lost, and saying so is
    # the difference between an instruction and a gamble. It is still a CHOICE —
    # a branch deliberately cut at an older commit was cut there on purpose.
    printf '    Fix:    git branch -f %s %s   (a fast-forward: %s has no commits of its own,\n' "$mb" "$base" "$mb"
    printf '            so nothing is lost — do this only if you meant to base this mission\n'
    printf '            on %s rather than %s)\n' "$base" "$tipshort"
  else
    # NEVER `git branch -f` here: it would silently discard commits that exist
    # nowhere else. The command is right and its RESULT is right, but it CHECKS
    # THE MISSION BRANCH OUT and leaves the captain there — a silent relocation,
    # in a guard whose own doctrine is "LCARS will not check out another branch".
    # The command does not change; it just stops being coy about what it does.
    printf '    Fix:    git rebase %s %s   (%s carries %s commit(s) of its own, which\n' "$base" "$mb" "$mb" "$ahead"
    printf '            forcing the branch pointer would DESTROY — so rebase, and do NOT\n'
    printf '            force it. Note it leaves you on %s: git checkout %s\n' "$mb" "${hb:--}"
    printf '            brings you back)\n'
  fi
  printf '\n'
  return 0
}

# ---------------------------------------------------------------------------
# THE DRIVE-TIME MISSION-BRANCH ADVANCE (S159, captain ruling 2026-07-31)
# ---------------------------------------------------------------------------
# BRINGING THE BASE UP TO DATE IS NOT THE GOAL. `mission_branch_block` in
# skills/lcars-run/run.sh pins every Research / Validate / Plan / Plan Review
# worker to `lcars/<id>` and tells it, in those words, to IGNORE the ambient
# checkout — so a drive that fast-forwards `main` and leaves the mission branch on
# its filing-time tip still hands every Stage the stale tree. The captain's ruling
# is that the drive must move the MISSION BRANCH too.
#
# IT MOVES IT ONLY WHEN THAT IS LOSSLESS: zero commits of its own relative to the
# base (`git rev-list --count <base>..<mb>` = 0), which is exactly the case S158's
# own file-time reporter already describes as "a fast-forward: no commits of its
# own, so nothing is lost". One commit of its own and the branch is left where it
# is, with the loud ⚠ block and its `git rebase` fix — forcing the pointer there
# would DESTROY work that exists nowhere else.
#
# FILE TIME IS UNCHANGED. `lcars_base_branch_note` above is the file-time voice
# and keeps every word of it: at filing, "a branch cut at an older commit was cut
# there on purpose" (S158), so it reports and offers `git branch -f` as a CHOICE.
# The drive-time voice is `lcars_base_branch_note_drive`, a SEPARATE function, for
# the reason the two must not blur: once LCARS really does move the branch, the
# file-time sentence "LCARS never moves a branch that may already carry work" is
# false of a drive, and its `git branch -f` Fix line is an instruction to do a
# thing already done. Two situations, two functions, no shared prose.
#
# THREE LANES, AND THE LANE IS DECIDED BY WHERE THE BRANCH IS CHECKED OUT —
# `git worktree list --porcelain`, never a guess:
#
#   not checked out anywhere       `git branch -f <mb> <base-sha>`. A pure pointer
#                                  move; given ahead == 0 it is a fast-forward by
#                                  construction, and it touches no working tree.
#   checked out, tree CLEAN        `git -C <worktree> merge --ff-only <base-sha>`.
#                                  `git branch -f` FAILS outright on a checked-out
#                                  branch ("cannot force update the branch …
#                                  checked out at …"), including in a worktree
#                                  whose directory is gone. A real fast-forward in
#                                  place is the only move that works, and it
#                                  leaves that checkout on the SAME branch — no
#                                  checkout, no detach, no HEAD relocation.
#   checked out, tree DIRTY        REFUSE. S158's doctrine is absolute: LCARS
#                                  never writes into a dirty tree. Say which
#                                  checkout, what kind of dirt, and give the one
#                                  command that clears it.
#
# `git merge --ff-only` will HAPPILY run in a dirty tree when the incoming commits
# do not touch the modified files — verified — so the dirty refusal is LCARS's own
# check, not something git can be relied on to make for it.
#
# A `child-base` Mission is out of scope by the same ruling: a logged bug's base is
# its parent's branch, LCARS takes no position on it, and the parent's branch is
# never moved. `drive_base_recheck` does not call this at all for that verdict.
#
# Exported globals (deliberately NOT part of the verdict vocabulary — the verdict
# stays the five names, and "did the mission branch move" is a different question
# with its own field, `missionBranchAtBase`):
#     LCARS_MB_MOVE     moved | refused | ''   ('' = nothing to decide)
#     LCARS_MB_BEHIND   commits the base has that the mission branch does not
#     LCARS_MB_AHEAD    commits of its own — the number that decides losslessness
#     LCARS_MB_REASON   one sentence naming what actually happened
#     LCARS_MB_FIX      ONE runnable command (may be empty), gloss after 3 spaces
#     LCARS_MB_NOTE     the way forward when NO command exists — displayed as an
#                       unlabelled `Note:` row, never as a `Fix:`. The sibling of
#                       LCARS_BASE_FIXNOTE, and for the same reason: a lane that
#                       cannot offer a command must still leave the captain
#                       somewhere to go (S160 round 3, D1).
#     LCARS_MB_WT       the checkout it found, when there was one

# _lcars_base_worktree_of <branch> — the worktree path where refs/heads/<branch> is
# checked out, or EMPTY. Sets LCARS_MB_WT.
#
# `git worktree list --porcelain` is asked, not guessed: the ambient tree and every
# linked mission worktree appear in the same list, so "checked out in the captain's
# own clone" and "checked out in a mission worktree" are one lane, decided by one
# question. `-z` is used because a worktree path may contain any byte — a newline
# included — and the line format would split one path into two records; the line
# format is the fallback for a git too old for `-z`.
_lcars_base_worktree_of() {
  local g want rec path="" hits=0
  g="$(_lcars_base_git)"
  LCARS_MB_WT=""
  [ -n "${1:-}" ] || return 0
  want="branch refs/heads/$1"
  while IFS= read -r -d '' rec; do
    hits=$((hits + 1))
    case "$rec" in
      "worktree "*) path="${rec#worktree }" ;;
    esac
    [ "$rec" = "$want" ] && LCARS_MB_WT="$path"
  done < <("$g" worktree list --porcelain -z 2>/dev/null)
  [ "$hits" -gt 0 ] && return 0
  path=""
  while IFS= read -r rec; do
    case "$rec" in
      "worktree "*) path="${rec#worktree }" ;;
    esac
    [ "$rec" = "$want" ] && LCARS_MB_WT="$path"
  done < <("$g" worktree list --porcelain 2>/dev/null)
  return 0
}

# lcars_base_advance_mission_branch <mission-branch> <base> — the move itself.
# ALWAYS returns 0: like everything else in this guard it is best-effort and never
# the thing that stops a drive.
lcars_base_advance_mission_branch() {
  local g mb="${1:-}" base="${2:-}" tip basesha behind ahead wt dirty out rc q stashargs clob
  g="$(_lcars_base_git)"
  LCARS_MB_MOVE=""; LCARS_MB_BEHIND=""; LCARS_MB_AHEAD=""
  LCARS_MB_REASON=""; LCARS_MB_FIX=""; LCARS_MB_NOTE=""; LCARS_MB_WT=""
  [ -n "$mb" ] && [ -n "$base" ] || return 0
  # A Mission whose branch IS the base has nothing to reconcile.
  [ "$mb" != "$base" ] || return 0
  tip="$("$g" rev-parse --verify -q "refs/heads/$mb" 2>/dev/null)" || tip=""
  basesha="$("$g" rev-parse --verify -q "refs/heads/$base" 2>/dev/null)" || basesha=""
  # No branch (an empty repo) or no local base: `ensure_base_current`'s own
  # warnings already cover those, and a second one would be noise.
  [ -n "$tip" ] && [ -n "$basesha" ] || return 0

  behind="$(_lcars_base_count "$tip" "$basesha")"
  # EMPTY means NOT MEASURED, and the whole record's doctrine is that an
  # unmeasured number is never substituted with a reassuring one. Say nothing.
  case "$behind" in ''|*[!0-9]*) return 0 ;; esac
  LCARS_MB_BEHIND="$behind"
  # Already contains the base — the ordinary in-flight state. Nothing to do.
  [ "$behind" = "0" ] && return 0

  ahead="$(_lcars_base_count "$basesha" "$tip")"
  case "$ahead" in
    ''|*[!0-9]*)
      LCARS_MB_MOVE="refused"
      LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base', but LCARS could not measure how many commits of its own it carries — and it only fast-forwards a mission branch when that is provably lossless, so nothing was moved."
      return 0 ;;
  esac
  LCARS_MB_AHEAD="$ahead"

  # --- lane 0: the branch carries WORK. Never move it. ---------------------
  if [ "$ahead" != "0" ]; then
    local hb; hb="$("$g" symbolic-ref -q --short HEAD 2>/dev/null)" || hb=""
    LCARS_MB_MOVE="refused"
    LCARS_MB_REASON="'$mb' carries $ahead commit(s) of its own. LCARS fast-forwards a mission branch onto its base ONLY when that is lossless — no commits of its own — and forcing this pointer would DESTROY those $ahead commit(s), so nothing was moved."
    LCARS_MB_FIX="git rebase $base $mb   (rebase, and do NOT force it. It leaves you on $mb: git checkout ${hb:--} brings you back)"
    return 0
  fi

  # --- from here the move is LOSSLESS: `$mb` is an ancestor of `$base`. ----
  _lcars_base_worktree_of "$mb"
  wt="$LCARS_MB_WT"

  # --- lane 1: not checked out anywhere → a pure pointer fast-forward ------
  if [ -z "$wt" ]; then
    rc=0; out="$("$g" branch -f "$mb" "$basesha" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      LCARS_MB_MOVE="moved"
      LCARS_MB_REASON="It carried no commits of its own and is not checked out anywhere, so its branch pointer was fast-forwarded onto '$base' — nothing was lost and no working tree was written to."
    else
      # No Fix line: the only command that would clear this is the one that just
      # failed, and a Fix that cannot succeed is not a Fix (S158, seven of them).
      # Recorded through the setter that HAS no fix slot, so it stays that way —
      # and that setter supplies the way forward, so "no command" never means
      # "no way out" (S160 round 3, D1).
      _lcars_mb_refused_after_attempt \
        "'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but git refused to move it: $(printf '%s' "$out" | head -1)" \
        "git refused to move the branch pointer itself, so there is no command LCARS can offer: running the same move again only repeats the refusal. Clear whatever git objected to — its own words are in the reason above — and $mb fast-forwards on the next drive."
    fi
    return 0
  fi

  q="$(_lcars_base_render_paths "$wt")"

  # --- the checkout is registered but GONE (a removed worktree dir). -------
  # `git branch -f` refuses for THIS branch even then ("cannot force update the
  # branch … checked out at …"), and `git -C` cannot run there at all — verified.
  if [ ! -d "$wt" ] || ! "$g" -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    LCARS_MB_MOVE="refused"
    LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but git still has it registered as checked out at $q — a directory that is no longer there — and it refuses to move a checked-out branch, so nothing was moved."
    LCARS_MB_FIX="git worktree prune   (drops the dead registration; the next drive then fast-forwards $mb for you)"
    return 0
  fi

  # --- lane 2: checked out with a DIRTY tree → refuse ----------------------
  # `git merge --ff-only` really does run in a dirty tree when the incoming
  # commits happen not to touch the modified files, so this refusal is LCARS's,
  # not git's. The captain's uncommitted work is never a thing a drive writes over.
  dirty="$("$g" -C "$wt" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    _lcars_base_dirt "$dirty"
    stashargs="${LCARS_BASE_DIRT_STASH#git }"
    LCARS_MB_MOVE="refused"
    LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but it is checked out at $q whose working tree has ${LCARS_BASE_DIRT_DESC:-uncommitted change(s)} — LCARS never writes into a dirty tree, so your uncommitted work is untouched and the branch was left where it was."
    LCARS_MB_FIX="git -C $q $stashargs && git -C $q merge --ff-only $base   (your work is stashed, not lost — git -C $q stash pop restores it)"
    return 0
  fi

  # --- would the fast-forward EAT an untracked/gitignored file? ------------
  # Same bar as the base's own step 8: `git status` reads clean with a gitignored
  # build artifact sitting there, and a fast-forward LCARS chose is held higher
  # than one the captain typed. The helper judges the tree it is standing in.
  clob="$( cd "$wt" 2>/dev/null && _lcars_base_clobber_paths "$tip" "$basesha" )"
  if [ -n "$clob" ]; then
    LCARS_MB_MOVE="refused"
    LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but fast-forwarding it in its checkout at $q would OVERWRITE local file(s) git is not tracking, whose content differs from the incoming one — so nothing was moved and your file(s) are intact: $(_lcars_base_render_paths "$clob")"
    LCARS_MB_FIX="move or delete those file(s), then   git -C $q merge --ff-only $base"
    return 0
  fi

  # --- lane 3: checked out and CLEAN → advance it in place ----------------
  rc=0; out="$("$g" -C "$wt" merge --ff-only "$basesha" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    LCARS_MB_MOVE="moved"
    LCARS_MB_REASON="It carried no commits of its own and is checked out at $q with a clean tree, so it was fast-forwarded there — nothing was lost, that checkout is still on $mb, and no HEAD was moved."
  else
    # Same rule, same recorder: LCARS ran this merge and git refused it, so the
    # merge is not on offer as the remedy for its own refusal — and the way
    # forward rides along as the recorder's note, so the block is a diagnosis
    # WITH an exit rather than a dead end (S160 round 3, D1).
    _lcars_mb_refused_after_attempt \
      "'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but the local fast-forward in its checkout at $q failed ($(printf '%s' "$out" | head -1)) — the ref was not moved and nothing was written." \
      "git refused this merge itself, so there is no command LCARS can offer: running the same merge again only repeats the refusal. Clear whatever git objected to — its own words are in the reason above — and $mb fast-forwards on the next drive."
  fi
  return 0
}

# lcars_base_branch_note_drive — the DRIVE-TIME voice, and ONLY that. It reports
# what `lcars_base_advance_mission_branch` just did; it decides nothing itself, so
# the words and the git operation cannot drift apart. Style follows
# `lcars_base_report` (one long line per field) rather than the file-time note's
# hand-wrapped prose — deliberately, so the two are not mistakable for each other
# and so every `Fix:` is one copyable command with its gloss after three spaces.
lcars_base_branch_note_drive() {
  [ "${LCARS_BASE_QUIET:-0}" = "1" ] && return 0
  local mb="${1:-}" base="${2:-}"
  case "${LCARS_MB_MOVE:-}" in
    moved)
      printf '  ✓ MISSION BRANCH — %s fast-forwarded %s commit(s) onto %s.\n' \
        "$mb" "${LCARS_MB_BEHIND:-?}" "$base"
      printf '    %s\n' "$LCARS_MB_REASON"
      ;;
    refused)
      printf '\n'
      printf '  ⚠ MISSION BRANCH — %s is %s commit(s) behind %s, and LCARS did not move it\n' \
        "$mb" "${LCARS_MB_BEHIND:-?}" "$base"
      printf '    Why:    %s\n' "$LCARS_MB_REASON"
      [ -n "${LCARS_MB_FIX:-}" ] && printf '    Fix:    %s\n' "$LCARS_MB_FIX"
      # `Note:` is the row for a lane with no command — the same split
      # `lcars_base_report` makes, so a captain reading either block learns the
      # same thing: `Fix:` is always pasteable, and guidance is never dressed as
      # a command. A refused lane always has one of the two.
      [ -n "${LCARS_MB_NOTE:-}" ] && printf '    Note:   %s\n' "$LCARS_MB_NOTE"
      printf '    Means:  every Stage in this drive reads %s, so it will reason about that older tree.\n' "$mb"
      printf '    Impact: %s\n' "$LCARS_BASE_IMPACT"
      printf '\n'
      ;;
  esac
  return 0
}

# lcars_base_state_json [mission-branch] — the RECORD itself, as one JSON object
# on one line, or nothing when no check has run.
#
# S160 lifted this out of lcars_base_state_line because the record now has TWO
# consumers: a Mission's state.json (via the line below) and the viewscreen's
# read-only reporter, which hands the same object to the board so the badge can
# carry the guard's OWN `reason` and `fix` rather than composing a second
# sentence about git state. Two printf statements would be two vocabularies, and
# the badge would eventually describe a condition the mission file denies.
#
# `behindBy` is `null` unless staleness was really measured — `0` is reserved for
# a measured zero, because a reassuring zero from a check that measured nothing
# is the one lie a consumer cannot detect. `missionBranchAtBase` answers what
# `baseSha` alone cannot (baseSha is the BASE's sha, and a reused `lcars/<id>`
# may not be on it) and is `null` when no mission branch was named. An unknown
# sha is `null` too: an empty string is a value a consumer cannot tell from a
# real one.
lcars_base_state_json() {
  [ -n "${LCARS_BASE_VERDICT:-}" ] || return 0
  local behind="${LCARS_BASE_BEHIND:-}" ahead="${LCARS_BASE_AHEAD:-}" atbase="null" mb="${1:-}" g tip shaj="null" loud="false"
  case "$behind" in ''|*[!0-9]*) behind="null" ;; esac
  case "$ahead"  in ''|*[!0-9]*) ahead="null"  ;; esac
  if [ -n "$mb" ]; then
    g="$(_lcars_base_git)"
    tip="$("$g" rev-parse --verify -q "refs/heads/$mb" 2>/dev/null)" || tip=""
    if [ -n "$tip" ] && [ -n "${LCARS_BASE_SHA:-}" ]; then
      if [ "$tip" = "$LCARS_BASE_SHA" ]; then atbase="true"; else atbase="false"; fi
    fi
  fi
  [ -n "${LCARS_BASE_SHA:-}" ] && shaj="\"$LCARS_BASE_SHA\""
  [ "${LCARS_BASE_LOUD:-0}" = "1" ] && loud="true"
  printf '{ "verdict": "%s", "loud": %s, "reason": "%s", "fix": "%s", "fixNote": "%s", "blocker": "%s", "behindBy": %s, "aheadBy": %s, "baseSha": %s, "checkedAt": "%s", "missionBranchAtBase": %s }' \
    "$LCARS_BASE_VERDICT" "$loud" \
    "$(lcars_json_escape "${LCARS_BASE_REASON:-}")" "$(lcars_json_escape "${LCARS_BASE_FIX:-}")" \
    "$(lcars_json_escape "${LCARS_BASE_FIXNOTE:-}")" "$(lcars_json_escape "${LCARS_BASE_BLOCKER:-}")" \
    "$behind" "$ahead" "$shaj" "${LCARS_BASE_CHECKED_AT:-}" "$atbase"
  return 0
}

# lcars_base_state_line [mission-branch] — the ONE-LINE state.json field (with its
# trailing comma), or nothing when no check has run. One line on purpose: run.sh's
# state_set_*/state_del editors are line-oriented, so a multi-line object would not
# survive a later stage's write. It is the object above, wrapped — nothing else.
lcars_base_state_line() {
  local obj; obj="$(lcars_base_state_json "${1:-}")"
  [ -n "$obj" ] || return 0
  printf '  "baseFreshness": %s,' "$obj"
  return 0
}

# ensure_base_current <base-branch> — the guard itself. ALWAYS returns 0.
ensure_base_current() {
  local base="${1:-main}"
  local g dirty n remote_sha local_sha head_branch head_desc ahead behind
  local trunk trunk_sha frc clob first fsecs how mergeout nofix nonote unborn
  local remote_missing=0 probe_alive="" probe_trunk="" probe_ran=0
  g="$(_lcars_base_git)"
  fsecs="$(_lcars_base_fetch_secs)"
  _lcars_base_envp

  LCARS_BASE_BRANCH="$base"
  LCARS_BASE_VERDICT=""
  LCARS_BASE_LOUD=0
  LCARS_BASE_BEHIND=""          # "" = NOT MEASURED (persisted as JSON null)
  LCARS_BASE_AHEAD=""           # same doctrine: "" = NOT MEASURED
  LCARS_BASE_SHA=""
  LCARS_BASE_REASON=""
  LCARS_BASE_FIX=""
  LCARS_BASE_FIXNOTE=""
  LCARS_BASE_BLOCKER=""
  LCARS_BASE_TRUNK=""
  LCARS_BASE_CHECKED_AT="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)}"

  # Kill switch, mirroring LCARS_VERSION_CHECK=0: zero network, zero output. The
  # sha is still resolved — it costs one local rev-parse and an empty baseSha
  # would be a hole in the record for no reason.
  if [ "${LCARS_BASE_FRESHNESS:-1}" = "0" ]; then
    _lcars_base_set unknown 0 \
      "the base-freshness guard is switched off (LCARS_BASE_FRESHNESS=0), so nothing was checked."
    lcars_base_report
    return 0
  fi

  # 0 — not a git repo at all. The caller already handles this; stay silent.
  if ! "$g" rev-parse --git-dir >/dev/null 2>&1; then
    _lcars_base_set unknown 0 "not inside a git repository — nothing to check."
    lcars_base_report
    return 0
  fi

  # 0a — git is MID-OPERATION here (S160 round 2). Checked before the child-base
  #      lane, before any network call and before a single ref is measured,
  #      because an unfinished rebase/merge/cherry-pick/revert/bisect is the one
  #      fact that makes every other measurement a measurement of a transient:
  #      `refs/heads/<base>` is where the operation will move it FROM, and HEAD
  #      is a replay position. The observed record said `stale`, "a fast-forward
  #      is impossible, so nothing was moved", and named a `baseSha` the Mission
  #      was NOT cut from — three claims about a repo in the middle of a rebase.
  #
  #      `unknown` and LOUD: freshness genuinely could NOT be determined, and
  #      this is not a state to discover afterwards. behindBy/aheadBy stay
  #      UNMEASURED (null) — the doctrine that a reassuring number from a check
  #      that measured nothing is the one lie a consumer cannot detect.
  _lcars_base_inflight
  if [ -n "${LCARS_BASE_INFLIGHT:-}" ]; then
    local op where unm short hb2 opfix
    op="$LCARS_BASE_INFLIGHT"
    # The ONLY unfinished operation with a one-line, lossless end. See
    # `_lcars_base_inflight_note` for why the others have no command at all.
    opfix=""
    [ "$op" = "bisect" ] && opfix="git bisect reset"
    hb2="$("$g" symbolic-ref -q --short HEAD 2>/dev/null)" || hb2=""
    if [ -n "$hb2" ]; then
      where="on '$hb2'"
    else
      short="$("$g" rev-parse --short HEAD 2>/dev/null)" || short=""
      if [ -n "$short" ]; then where="with HEAD detached at $short"; else where="with a detached HEAD"; fi
    fi
    unm=""
    [ "${LCARS_BASE_INFLIGHT_UNMERGED:-0}" -gt 0 ] 2>/dev/null && \
      unm=", and $LCARS_BASE_INFLIGHT_UNMERGED path(s) are still unmerged"
    # NOT "nothing was moved" — that sentence describes a settled repo, and this
    # one is mid-operation. What LCARS did is all LCARS may claim.
    _lcars_base_set unknown 1 \
      "an unfinished git $op is in progress here, $where$unm — the refs are mid-move, so LCARS measured nothing against origin and did nothing of its own. Finish or abandon the $op and the check runs normally again." \
      "$opfix" \
      "operation-in-progress" \
      "$(_lcars_base_inflight_note "$op")"
    # baseSha is NULL here, deliberately. The record's own doctrine is that it
    # never substitutes a real-looking value a consumer cannot check: mid-rebase,
    # `refs/heads/<base>` is a commit the Mission is NOT cut from, and stamping
    # it made a PERMANENT, wrong provenance record. "Could not be determined" is
    # the only honest answer while the operation is unfinished.
    LCARS_BASE_SHA=""
    lcars_base_report
    return 0
  fi

  # 0b — the base is ANOTHER MISSION's branch (S159). Checked before ANY network
  #      call and before any ref is looked at, because there is no version of
  #      this question worth asking: a logged bug is based on its parent's
  #      `lcars/<parent-id>` branch, and origin's trunk is not what that branch
  #      is supposed to contain. Bringing it "up to date" would move the fix onto
  #      code it was never written against — the failure this lane exists to
  #      prevent. Take no network call, move no ref, and say so.
  if lcars_base_is_mission_branch "$base"; then
    _lcars_base_set child-base 0 \
      "'$base' is an LCARS Mission branch, not a trunk — this Mission is based on another Mission's work (a logged bug's fix belongs on its parent's branch), so there is nothing to bring down from origin. Nothing was fetched and no ref was moved."
    lcars_base_report
    return 0
  fi

  # 1 — no `origin`. The everyday local-only repo: there is nothing to be stale
  #     against, so this must be indistinguishable from pre-S158 behaviour.
  if ! "$g" config --get remote.origin.url >/dev/null 2>&1; then
    _lcars_base_set unknown 0 \
      "this repo has no 'origin' remote — there is nothing to be stale against."
    lcars_base_report
    return 0
  fi

  # 2 — is the tree dirty? Noted now, acted on LATER. A dirty tree forbids the
  #     fast-forward, not the measurement: a fetch writes only into refs/remotes/
  #     and provably cannot touch the working tree, and "you are 19 behind" is a
  #     warning a captain can act on where "you might be behind" is one they
  #     dismiss.
  dirty="$("$g" status --porcelain 2>/dev/null)"
  LCARS_BASE_DIRT_DESC=""; LCARS_BASE_DIRT_STASH="git stash"
  if [ -n "$dirty" ]; then
    _lcars_base_dirt "$dirty"
  fi
  n="${LCARS_BASE_DIRT_DESC:-}"

  # 3 — fetch: NARROW, ANNOUNCED, BOUNDED and INCAPABLE of prompting. One branch,
  #     no tags, into one remote-tracking ref.
  frc=0
  _lcars_base_fetch_ref "$base" || frc=$?
  remote_missing=0
  probe_alive=""
  if [ "$frc" -ne 0 ]; then
    # A narrow fetch fails for two very different reasons, and the difference
    # matters to every sentence printed below. Ask origin one bounded question.
    _lcars_base_probe "$base"
    probe_ran=1
    probe_alive="$LCARS_BASE_PROBE_RC"
    if [ "$LCARS_BASE_PROBE_RC" -eq 0 ] && [ "$LCARS_BASE_PROBE_HASBASE" -ne 0 ]; then
      # Origin is fine and simply has no branch by that name: the everyday
      # unpushed topic branch. Not a failure — fall through to the trunk lane.
      remote_missing=1
      frc=0
      probe_trunk="$LCARS_BASE_PROBE_TRUNK"
    fi
  fi
  if [ "$frc" -ne 0 ]; then
    # Nothing could be measured on any of these paths, so the verdict is
    # `unknown` — including when the tree is also dirty. Saying `stale` would
    # assert a staleness LCARS never established.
    if [ "$frc" -eq 124 ] && [ "${probe_alive:-1}" -eq 0 ]; then
      # ORIGIN ANSWERED — instantly — it was the fetch that ran long. Calling
      # this "unreachable" was false.
      first="fetching origin/$base timed out after ${fsecs}s (set LCARS_BASE_FETCH_TIMEOUT_SECS to change that), but origin ANSWERED a plain ref listing straight away — it is reachable, just slower than LCARS is willing to make you wait, so '$base' was not measured."
      if [ -n "$dirty" ]; then
        # Origin IS reachable here (it answered instantly), so a pull really can
        # succeed — the fix is one runnable line, and the timeout advice is the
        # note beside it.
        #
        # THE BLOCKER IS THE TIMEOUT, NOT THE DIRT (S160 round 3, D2). The tree
        # really is dirty, but a "DIRTY TREE" headline would name a condition
        # that is present and is not the reason — nothing was measured at all,
        # because the fetch ran long. Naming the fetch is what makes the badge
        # agree with the sentence under it. Leaving it EMPTY, which is what this
        # lane used to do, was the other half of the same problem: it fell back
        # to the generic ⚠ BASE UNVERIFIED and named nothing at all, while its
        # `unreachable` sibling named itself.
        _lcars_base_set unknown 1 \
          "the working tree has $n, and $first Nothing was written to your tree." \
          "$(_lcars_base_dirty_fix "$base")" \
          "fetch-timeout" \
          "$LCARS_BASE_DIRT_NOTE Origin is reachable, just slow — raising LCARS_BASE_FETCH_TIMEOUT_SECS and re-filing works too."
      else
        _lcars_base_set unknown 1 "$first" \
          "git fetch origin $base" \
          "fetch-timeout" \
          "origin is reachable, just slower than LCARS waits — raising LCARS_BASE_FETCH_TIMEOUT_SECS and re-filing works too."
      fi
    else
      if [ "$frc" -eq 124 ]; then
        first="fetching origin/$base timed out after ${fsecs}s (set LCARS_BASE_FETCH_TIMEOUT_SECS to change that), and origin did not answer a plain ref listing either — LCARS could not check whether '$base' is behind."
      else
        first="could not fetch from origin (offline, auth, or the remote is unreachable) — LCARS could not check whether '$base' is behind."
      fi
      if [ -n "$dirty" ]; then
        # The old fix was `git stash … then git pull`, and a tester verified the
        # pull fails from here ("Please make sure you have the correct access
        # rights"). A fix that cannot succeed is not a fix — origin has to come
        # back first. So there is NO `fix` on this lane at all: no command run
        # from this repo clears an unreachable origin, and offering one anyway is
        # what got seven fix strings caught in S158. The route back lives in the
        # note, where nothing labels it a command.
        _lcars_base_set unknown 1 \
          "the working tree has $n, and $first Nothing was written to your tree, and until origin answers no command can bring '$base' up to date." \
          "" \
          "unreachable" \
          "reach origin first (VPN / network / auth); once it answers, '$(_lcars_base_dirty_fix "$base")' brings '$base' up to date. $LCARS_BASE_DIRT_NOTE"
      else
        _lcars_base_set unknown 1 "$first" \
          "" \
          "unreachable" \
          "reach origin first (VPN / network / auth); once it answers, 'git fetch origin $base' measures '$base' again."
      fi
    fi
    lcars_base_report
    return 0
  fi

  local_sha="$("$g" rev-parse --verify -q "refs/heads/$base" 2>/dev/null)" || local_sha=""
  if [ "$remote_missing" -eq 1 ]; then
    # Origin told us it has no such branch. A stale remote-tracking ref left over
    # from an older clone must not be allowed to contradict that.
    remote_sha=""
  else
    remote_sha="$("$g" rev-parse --verify -q "refs/remotes/origin/$base" 2>/dev/null)" || remote_sha=""
  fi

  # 4 — the base has NO counterpart on origin. This is the captain doing the
  #     ordinary thing — `git checkout -b my-wip`, or working in a linked worktree
  #     on an unpushed branch — and calling it "nothing to be stale against" is
  #     false: a topic branch is stale against the trunk it was cut from; that is
  #     the whole concept. So measure against origin's DEFAULT branch and shout
  #     when it is behind. NEVER pull the trunk into a topic branch — that is a
  #     merge, which this guard is forbidden to make. Measure and warn only.
  if [ -z "$remote_sha" ]; then
    # The trunk is resolved from the probe's answer when one was taken (no second
    # network call), and its objects are fetched just as narrowly as the base's.
    _lcars_base_resolve_trunk "$probe_trunk" "$probe_ran"
    trunk="$LCARS_BASE_TRUNK_NAME"
    trunk_sha=""
    if [ -n "$trunk" ]; then
      _lcars_base_fetch_ref "$trunk" || true
      trunk_sha="$("$g" rev-parse --verify -q "refs/remotes/origin/$trunk" 2>/dev/null)" || trunk_sha=""
    fi
    if [ -z "$trunk_sha" ]; then
      # The fix must be a command that can SUCCEED from here. The old one —
      # `git remote set-head origin <name>` — cannot: set-head requires
      # refs/remotes/origin/<name> to exist locally, and on the very fixture that
      # produces this verdict (an EMPTY origin) it never does; `--auto` fails too
      # ("Cannot determine remote HEAD"). What actually ends this condition is
      # giving origin a branch to be measured against.
      if [ -n "$("$g" rev-parse --verify -q "refs/heads/$base" 2>/dev/null)" ]; then
        nofix="git push -u origin $base"
        nonote="origin has no branch to measure '$base' against — pushing it gives LCARS one."
      elif "$g" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        nofix="git branch $base && git push -u origin $base"
        nonote="neither this repo nor origin has a '$base' branch yet."
      else
        # NO COMMITS AT ALL. `$base` is not to be trusted here: `git rev-parse
        # --abbrev-ref HEAD` FAILS on an unborn HEAD, so file.sh falls back to
        # the literal string `main` — while the branch the captain's first commit
        # will actually land on is whatever `init.defaultBranch` says, and git's
        # stock default is `master`. The old fix named `main` and obeying it
        # errored outright ("error: src refspec main does not match any").
        # `symbolic-ref --short HEAD` DOES answer on an unborn HEAD: it is the
        # honest name of the branch the captain is already on. Round 4, D1.
        # And there is no COMMAND here at all: "make your first commit" is not
        # one, and a bare `git push` from a repo with no commits errors out
        # ("src refspec … does not match any"). Empty fix, honest note.
        unborn="$("$g" symbolic-ref -q --short HEAD 2>/dev/null)" || unborn=""
        [ -n "$unborn" ] || unborn="$base"
        nofix=""
        nonote="this repo has no commits and origin has no branches — make your first commit, then 'git push -u origin $unborn' gives LCARS something to measure."
      fi
      _lcars_base_set unknown 1 \
        "origin has no '$base' branch, and origin's DEFAULT branch could not be resolved either — so LCARS could not measure whether '$base' is out of date at all." \
        "$nofix" "" "$nonote"
      lcars_base_report
      return 0
    fi
    LCARS_BASE_TRUNK="$trunk"
    if [ -z "$local_sha" ]; then
      _lcars_base_set unknown 1 \
        "there is no local '$base' branch, and origin has none either — nothing to compare or move, and this mission's branch is cut from HEAD as it stands." \
        "git fetch origin $trunk:$base"
      lcars_base_report
      return 0
    fi
    behind="$(_lcars_base_count "$local_sha" "$trunk_sha")"
    LCARS_BASE_BEHIND="$behind"
    LCARS_BASE_AHEAD="$(_lcars_base_count "$trunk_sha" "$local_sha")"
    if [ "${behind:-0}" = "0" ]; then
      _lcars_base_set current 0 \
        "origin has no '$base' branch (an unpushed local branch), and it already contains everything on origin/$trunk."
      lcars_base_report
      return 0
    fi
    _lcars_base_set stale 1 \
      "origin has no '$base' branch, so LCARS measured against origin/$trunk: '$base' is $behind commit(s) behind it. LCARS will not merge a trunk into a topic branch — that is a real merge, not a fast-forward — so nothing was moved." \
      "git merge origin/$trunk" \
      "behind-trunk" \
      "'git rebase origin/$trunk' is the other way to do it; either way, re-file afterwards."
    lcars_base_report
    return 0
  fi

  if [ -z "$local_sha" ]; then
    _lcars_base_set unknown 1 \
      "there is no local '$base' branch to compare against origin/$base — this mission's branch is cut from HEAD as it stands." \
      "git fetch origin $base:$base"
    lcars_base_report
    return 0
  fi

  if [ "$local_sha" = "$remote_sha" ]; then
    LCARS_BASE_BEHIND=0
    LCARS_BASE_AHEAD=0
    _lcars_base_set current 0 "local '$base' is exactly origin's '$base'."
    lcars_base_report
    return 0
  fi

  # Both distances, measured once, before any verdict is chosen. This guard cares
  # about exactly one of them: whether the base is MISSING something origin has.
  LCARS_BASE_BEHIND="$(_lcars_base_count "$local_sha" "$remote_sha")"
  LCARS_BASE_AHEAD="$(_lcars_base_count "$remote_sha" "$local_sha")"
  behind="${LCARS_BASE_BEHIND:-?}"
  ahead="${LCARS_BASE_AHEAD:-?}"

  # 5a — AHEAD ONLY: the most ordinary state there is — an unpushed local commit.
  #      The base contains everything origin has, which is the whole question this
  #      guard asks, so it is CURRENT and SILENT. It used to be shouted at as
  #      `stale` while the same record said `behindBy: 0`, under a fix
  #      (`git pull --rebase`) that is a literal no-op here, so re-filing
  #      reproduced the identical warning forever and only `git push` cleared it.
  if [ "${LCARS_BASE_BEHIND:-}" = "0" ]; then
    _lcars_base_set current 0 \
      "local '$base' already contains everything on origin/$base, and carries $ahead commit(s) origin does not yet have (unpushed) — nothing to bring down."
    lcars_base_report
    return 0
  fi

  # 5b — DIVERGED: behind AND ahead, so there is no fast-forward to make. Refuse
  #      and say so; never rebase, never merge. Reconciling really does clear this
  #      (afterwards the base is ahead-only, which 5a calls current).
  if ! "$g" merge-base --is-ancestor "$local_sha" "$remote_sha" >/dev/null 2>&1; then
    _lcars_base_set stale 1 \
      "local '$base' has $ahead commit(s) origin does not and is $behind commit(s) behind origin — a fast-forward is impossible, so nothing was moved." \
      "git pull --rebase origin $base" \
      "diverged" \
      "reconciling '$base' by hand works just as well; either way, re-file afterwards."
    lcars_base_report
    return 0
  fi

  # 6 — behind and fast-forwardable. Now the dirty tree matters: it forbids the
  #     fast-forward (and only the fast-forward).
  if [ -n "$dirty" ]; then
    _lcars_base_set stale 1 \
      "the working tree has $n — LCARS never writes into a dirty tree, so your own uncommitted work was not touched and '$base' was left $behind commit(s) behind origin." \
      "$(_lcars_base_dirty_fix "$base")" \
      "dirty-tree" \
      "$LCARS_BASE_DIRT_NOTE"
    lcars_base_report
    return 0
  fi

  # 7 — only move the ref when HEAD actually IS that branch; LCARS will not check
  #     out another branch to do it. `rev-parse --abbrev-ref HEAD` answers the
  #     literal string "HEAD" when detached (never empty), so the detached case is
  #     detected with symbolic-ref instead of a fallback that could never fire —
  #     the captain was reading "HEAD is on 'HEAD'".
  head_branch="$("$g" symbolic-ref -q --short HEAD 2>/dev/null)" || head_branch=""
  if [ "$head_branch" != "$base" ]; then
    if [ -n "$head_branch" ]; then head_desc="'$head_branch'"; else head_desc="a detached commit"; fi
    _lcars_base_set stale 1 \
      "local '$base' is $behind commit(s) behind origin, but HEAD is on $head_desc — LCARS will not check out another branch, so nothing was moved." \
      "git checkout $base && git pull --ff-only origin $base" \
      "not-checked-out"
    lcars_base_report
    return 0
  fi

  # 8 — would the fast-forward EAT something? `git status` reads clean with a
  #     gitignored build artifact sitting in the tree, and a pull the captain did
  #     not type would overwrite it without a word. A pull LCARS chose is held to
  #     a higher bar than one the captain typed: refuse, name the files, and let
  #     them decide.
  clob="$(_lcars_base_clobber_paths "$local_sha" "$remote_sha")"
  if [ -n "$clob" ]; then
    _lcars_base_set stale 1 \
      "'$base' is $behind commit(s) behind origin, but fast-forwarding it would OVERWRITE local file(s) git is not tracking, whose content differs from the incoming one — so nothing was moved and your file(s) are intact: $(_lcars_base_render_paths "$clob")" \
      "" \
      "untracked-clobber" \
      "no command can decide this for you: move or delete those file(s), then 'git pull --ff-only origin $base' brings '$base' up to date."
    lcars_base_report
    return 0
  fi

  # 8b — CHECK-ONLY (S160): stop here. Everything above only MEASURED; step 9 is
  #      the one step that writes, and this mode exists so the board can ask the
  #      question before the captain has typed a word without the asking of it
  #      moving their refs. THE CAPTAIN'S CLONE IS SACRED applies hardest to a
  #      write nobody requested.
  #
  #      `stale` and DELIBERATELY QUIET. Stale in the only sense the vocabulary
  #      has — behind, and not brought up to date. Quiet because every lane a
  #      captain must act on has already returned loud above, and this is the one
  #      lane where their next action, filing, IS the fix. Shouting here would be
  #      a warning whose only remedy is the thing they were already doing — the
  #      "re-file reproduces the identical warning forever" trap (see 5a).
  if [ "${LCARS_BASE_CHECK_ONLY:-0}" = "1" ]; then
    _lcars_base_set stale 0 \
      "local '$base' is $behind commit(s) behind origin and fast-forwards cleanly, but this was a READ-ONLY check — nothing was moved. Filing a Mission brings '$base' up to date first."
    lcars_base_report
    return 0
  fi

  # 9 — the move itself: a purely LOCAL fast-forward onto the sha we ALREADY
  #     fetched. No network, and — deliberately — no bound. The only way this
  #     guard could ever leave a half-written tree was a timeout landing
  #     mid-checkout, and there is now nothing to time out.
  frc=0
  mergeout="$("$g" merge --ff-only "$remote_sha" 2>&1)" || frc=$?
  if [ "$frc" -eq 0 ]; then
    _lcars_base_set updated 0 "fast-forwarded '$base' $behind commit(s) from origin."
  else
    how="$(printf '%s' "$mergeout" | head -1)"
    [ -n "$how" ] || how="git gave no reason"
    # NO `fix`, and the recorder is the one that CANNOT carry one. LCARS just
    # ran this merge and git refused it on its merits; offering `git merge
    # --ff-only origin/<base>` back was offering the captain the failure it had
    # already captured one line above — a tester pasted it and got the identical
    # `fatal: Commit … does not have a GPG signature.`, still 2 behind.
    _lcars_base_set_after_attempt stale 1 \
      "'$base' is $behind commit(s) behind origin and the LOCAL fast-forward onto the already-fetched origin/$base failed ($how) — the ref was not moved and your tree was not written to." \
      "merge-refused" \
      "git refused this merge itself, so there is no command LCARS can offer: running the same merge again only repeats the refusal. Clear whatever git objected to — its own words are in the reason above — and '$base' fast-forwards on the next filing."
  fi
  lcars_base_report
  return 0
}
# ---------------------------------------------------------------------------
# MERGE-PRESERVING CONFIG WRITE
# ---------------------------------------------------------------------------
# config.json is written by MERGE, never by clobber: existing values for keys
# already present are preserved untouched; only MISSING keys are filled in with
# the supplied defaults. This makes re-running init (and running update)
# idempotent — a captain's customized testCommand / model / comprehensionBudget
# survives. Both init and update call this so the behaviour cannot drift.

# lcars_json_escape — escape a string for embedding inside a JSON string literal.
# Backslashes are escaped FIRST, then double-quotes (the standard order — mirrors
# json_escape in skills/lcars-run/run.sh), then awk escapes every control char
# (newline/tab/CR → \n \t \r, the rest \u00XX) so ANY value yields VALID JSON.
# The result is safe to wrap in quotes. jq-free.
lcars_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # backslashes first…
  s="${s//\"/\\\"}"   # …then double-quotes
  printf '%s' "$s" | awk '
    BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
    { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
        if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
        else if (c=="\r") printf "\\r"
        else { b=index(MAP,c); if (b>0) printf "\\u%04x",b; else printf "%s",c } } }'
}

# ---------------------------------------------------------------------------
# S207 — THE ONE state.json FIELD WRITER lives in lcars-state.sh
# ---------------------------------------------------------------------------
# `lcars_state_set` / `lcars_state_set_string` / `lcars_state_unset` (and the
# one-line-object trio `lcars_json1_*`) are in a SEPARATE, self-contained file
# beside this one, and this file pulls them in so anything that sources
# lcars-common.sh has them.
#
# WHY A SEPARATE FILE. Eight scripts write state.json and every one of them
# needs the writer, but three of them (pause, respond, feedback) source no
# shared library at all, and run.sh deliberately does not source THIS one
# eagerly — it is re-entered as a subprocess for every Stage and every ticket,
# and it says so in its own words at drive_load_common ("sourcing a second
# library into all of them to serve none of them is blast radius for nothing").
# A 150-line file they can all source costs them nothing; a 4,000-line one
# would have forced a choice between that cost and a ninth copy of the writer.
LCARS_STATE_LIB="${LCARS_STATE_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lcars-state.sh}"
# shellcheck source=./lcars-state.sh
[ -f "$LCARS_STATE_LIB" ] && . "$LCARS_STATE_LIB"

# ---------------------------------------------------------------------------
# S195 — WHICH WORKER CLIs THIS MACHINE ACTUALLY HAS
# ---------------------------------------------------------------------------
# THE ONE DETECTOR, and it is deliberately the one that already existed: `lcars
# init` verifies the claude CLI with `command -v "${LCARS_CLAUDE_BIN:-claude}"`
# (init.sh), and this is that check, named, with its copilot sibling beside it.
# init.sh now calls it rather than open-coding the same line, so there is no
# second answer to "is this engine installed" anywhere in LCARS.
#
# WHY IT LIVES HERE and not in the daemon: the front-door engine picker must
# offer only engines that exist, and a picker that offers a CLI this machine
# does not have is a way to file a mission that cannot run. The daemon publishes
# the list through `establish-vision.sh --facts` — dispatch, never a second
# implementation in Python (ADR-002).
#
# `command -v`, and nothing cleverer: no `--version` probe (that costs a process
# spawn per engine on every board read), and no `~/.claude` / `~/.copilot`
# directory sniffing — run.sh's own host detection explicitly refuses that
# signal, and so does this.

# The engines LCARS drives, in the order every surface offers them. Same pair
# and same order as the daemon's `_HOLODECK_ENGINES` and the File console's
# picker; this is the shell-side home of it.
# ---------------------------------------------------------------------------
# THE RUNNING LCARS VERSION — the stamp `lcarsVersion` carries.
# ---------------------------------------------------------------------------
# ONE implementation, here, because THREE skills have to answer it identically:
# `lcars init` seeds the stamp, `lcars update` refreshes it, and (S207) `lcars
# adopt` seeds it on the config it writes for a cold clone. init and update each
# carried a byte-identical private copy; adopt would have been the third, and a
# third copy of "which version am I" is how the stamp starts disagreeing with
# itself.
#
# VERSION ships in the repo root (../.. from this file's own directory; -P
# resolves the install symlink to the physical checkout, so the answer is the
# CHECKOUT's version and not the symlink farm's). $LCARS_VERSION wins so a test
# can pin it; $LCARS_REPO redirects the checkout root. This mirrors the
# resolution in skills/lcars-version/version.sh.
#
# EMPTY IS A REAL ANSWER (no VERSION file): every caller then OMITS the key
# rather than seeding a bogus stamp.
lcars_running_version() {
  if [ -n "${LCARS_VERSION:-}" ]; then printf '%s' "$LCARS_VERSION"; return; fi
  local phys repo vf
  phys="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  repo="${LCARS_REPO:-$(cd "$phys/../.." 2>/dev/null && pwd -P)}"
  vf="$repo/VERSION"
  [ -f "$vf" ] || return 0
  sed -n '/[^[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p; q;}' "$vf"
}

LCARS_ENGINES="claude copilot"

# S217 — the ONE worker-bin guard (lcars_worker_bin_guard: refuse a `copilot`
# that resolves to VS Code's own re-invoking shim). It lives in its own small
# file so worker-adapter.sh can source it without this whole library; sourcing
# it here gives every skill that sources lcars-common.sh the same function.
# shellcheck source=worker-guard.sh
[ -f "$(dirname "${BASH_SOURCE[0]}")/worker-guard.sh" ] \
  && . "$(dirname "${BASH_SOURCE[0]}")/worker-guard.sh"

# lcars_engine_bin <engine> — the binary name/path to look for. Both are env
# seams so a test can pin what this machine "has" without touching $PATH (and
# so a wrapper script can stand in for either CLI). Exit 1 on an unknown engine.
lcars_engine_bin() {
  case "${1:-}" in
    claude)  printf '%s' "${LCARS_CLAUDE_BIN:-claude}" ;;
    copilot) printf '%s' "${LCARS_COPILOT_BIN:-copilot}" ;;
    *)       return 1 ;;
  esac
}

# lcars_engine_available <engine> — 0 iff that CLI is on this machine.
lcars_engine_available() {
  local b; b="$(lcars_engine_bin "${1:-}")" || return 1
  [ -n "$b" ] || return 1
  command -v "$b" >/dev/null 2>&1
}

# lcars_available_engines — the installed engines, one per line, canonical order.
# EMPTY output is a real and honest answer (neither CLI installed): the caller
# offers nothing rather than naming an engine that is not there.
lcars_available_engines() {
  local e
  for e in $LCARS_ENGINES; do
    lcars_engine_available "$e" && printf '%s\n' "$e"
  done
  return 0
}

# lcars_default_engine [config.json] — which engine a surface should PRESELECT:
#
#     the repo's configured workerBin (when it is installed)
#       >  the single installed engine
#       >  claude, the historical default run.sh falls back to
#
# The repo's own pin comes first because a repo that already has an engine must
# open on that engine, not on a default that would silently re-home it. A
# configured engine that is NOT installed is skipped rather than preselected —
# preselecting an engine the captain cannot run is worse than preselecting one
# he can. Empty when nothing at all is installed.
lcars_default_engine() { # [config]
  local cfg="${1:-}" cfgbin="" avail
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    cfgbin="$(lcars_config_get "$cfg" workerBin)"
  fi
  if [ -n "$cfgbin" ] && lcars_engine_available "$cfgbin"; then
    printf '%s' "$cfgbin"; return 0
  fi
  avail="$(lcars_available_engines)"
  case "$avail" in
    "") return 0 ;;
  esac
  if [ "$(printf '%s\n' "$avail" | grep -c .)" = "1" ]; then
    printf '%s' "$avail"; return 0
  fi
  case " $(printf '%s' "$avail" | tr '\n' ' ') " in
    *" claude "*) printf 'claude' ;;
    *)            printf '%s' "$(printf '%s\n' "$avail" | head -1)" ;;
  esac
}

# ===========================================================================
# lcars_xo_default_engine [config.json] — which engine NUMBER ONE's pickers
# open on. THE ONE PLACE THE ANSWER IS DECIDED, and it is deliberately not
# `lcars_default_engine`:
#
#     the repo's pinned `numberOne.engine` (when it is installed)
#       >  the first INSTALLED engine of LCARS_XO_ENGINE_PREFERENCE
#       >  nothing at all (neither CLI here — an honest empty answer)
#
# WHY IT IS A SECOND FUNCTION. `lcars_default_engine` answers a different
# question — which engine drives the captain's own mission, where the front
# door's historical answer is claude and a repo full of missions depends on it.
# Number One is the OTHER kind of drive: one LCARS starts on the captain's
# behalf, often while he is not watching.
#
# WHY COPILOT LEADS THE PREFERENCE (fix round 1, D2). LCARS's standing rule is
# that a live drive defaults to Copilot, and a bare Enter is exactly the answer
# a captain gives without reading — so it must land on the conservative engine,
# never on the metered one. The board's picker preselected copilot and this
# answered claude, which meant the SAME question got two answers depending on
# which door you came through. Both doors read this function now: the CLI
# picker calls it directly (`skills/lcars-xo/xo.sh`), and the daemon spawns it
# and publishes the answer as `meta.engineDefault` for the board's picker
# (`web/lcars_serve/local_adapter.py`). Change the order here and both move.
# ===========================================================================
LCARS_XO_ENGINE_PREFERENCE="copilot claude"

lcars_xo_default_engine() { # [config]
  local cfg="${1:-}" pinned="" e
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    pinned="$(lcars_config_get_raw "$cfg" numberOne \
      | sed -n 's/.*"engine"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi
  # A PIN THAT IS NOT INSTALLED IS SKIPPED, never preselected: offering an
  # engine the captain cannot run is worse than offering one he can.
  if [ -n "$pinned" ] && lcars_engine_available "$pinned"; then
    printf '%s' "$pinned"; return 0
  fi
  for e in $LCARS_XO_ENGINE_PREFERENCE; do
    lcars_engine_available "$e" && { printf '%s' "$e"; return 0; }
  done
  return 0
}

# ===========================================================================
# S309 — THE ENGINE THIS RUN RECORDED, read rather than re-guessed.
#
# THE DEFECT, MEASURED on the 21–22 Oct 2026 hands-off run: the run was started
# `lcars-ech init --engine copilot`, which WROTE `engine: copilot` into
# `.git/lcars/autopilot.json` — and `lcars init` then seeded
# `"model": "claude-sonnet"` anyway, because the seed was a constant that never
# looked at any engine at all. The two live missions were safe only because
# their own state.json happened to pin `workerBin: copilot`; a mission filed
# without an explicit engine would have run on Claude and billed a captain who
# had asked for Copilot-only. A cost surprise, not an inconsistency.
#
# This is the pre-flight *infer-vs-record* rule applied to configuration: the
# producer (`lcars-ech init`) already wrote the fact down, so the consumer reads
# the record instead of re-deriving it from what happens to be installed.
#
# A RECORD FOR AN ENGINE THAT IS NOT INSTALLED IS SKIPPED, never obeyed — the
# same rule `lcars_default_engine` and `lcars_xo_default_engine` already apply
# to a pin. Empty when there is no record, so a caller can tell "recorded" from
# "detected" and say which it used.
# ===========================================================================
lcars_recorded_run_engine() { # <lcars-dir> → the recorded engine, or empty
  local dir="${1:-}" ap e=""
  [ -n "$dir" ] || return 0
  ap="$dir/autopilot.json"
  [ -f "$ap" ] || return 0
  # autopilot.json is a NESTED record, but `engine` is a top-level scalar on its
  # own line (ech.sh writes it with json.dump), so the flat reader answers it.
  e="$(lcars_config_get "$ap" engine)"
  [ -n "$e" ] || return 0
  lcars_engine_available "$e" || return 0
  printf '%s' "$e"
}

# ===========================================================================
# S309 fix round 1, D2 — THE RECORD AS IT IS WRITTEN, before the availability
# filter. `lcars_recorded_run_engine` above answers "which recorded engine can
# we actually use", so it answers EMPTY for a record naming an engine that is
# not installed — which is correct, and is exactly why a caller cannot tell
# "nothing was recorded" from "a record was read and skipped".
#
# The readout needs that difference. Init was measured saying "nothing records
# which engine this repo runs on" with `{"engine":"copilot"}` sitting on disk:
# the record had been read, discarded as unavailable, and then denied. Skipping
# an unavailable pin is right; denying it is not. This reader exists ONLY so the
# sentence can be true — it is never used to choose an engine.
# ===========================================================================
lcars_recorded_run_engine_raw() { # <lcars-dir> → the engine as recorded, or empty
  local dir="${1:-}" ap
  [ -n "$dir" ] || return 0
  ap="$dir/autopilot.json"
  [ -f "$ap" ] || return 0
  lcars_config_get "$ap" engine
}

# ===========================================================================
# S309 — THE MODEL AN ENGINE ACTUALLY RUNS. The ONE place `lcars init` and
# `lcars update` answer "what goes in config.json's `model` for engine X".
#
#   claude  → `claude-sonnet`   the historical seed, unchanged, so every repo
#                               set up on Claude comes out byte-identical.
#   copilot → `claude-opus-5.5` what a copilot worker is REALLY spawned with.
#
# WHY copilot IS OPUS. That is run.sh's standing policy, not a new choice here:
# `alias_for_tier` (skills/lcars-run/run.sh) pins BOTH copilot tiers to
# `claude-opus-5.5`, and `web/lcars_serve/board.py` and `actions.py` each carry
# the same answer for their own surface. THE POLICY'S ONE HOME IS STILL
# `alias_for_tier` — this function is the SEED, the value a fresh config starts
# with, and it is deliberately not a second copy of the tier ladder (no
# estimator, no per-stage tiers, no `modelAliases` read). If the copilot model
# id moves again, the four places that name it move together; the grep is
# `claude-opus-5.5`.
#
# An unknown or empty engine answers the historical default rather than nothing:
# a config with no `model` key at all breaks every reader downstream.
# ===========================================================================
lcars_default_model_for_engine() { # <engine> → the model string for a fresh config
  case "${1:-}" in
    copilot) printf 'claude-opus-5.5' ;;
    *)       printf 'claude-sonnet' ;;
  esac
}

# lcars_config_has_key — 0 if the config file has a top-level "key": present.
lcars_config_has_key() {
  local config="$1" key="$2"
  [ -f "$config" ] || return 1
  grep -q "\"$key\"[[:space:]]*:" "$config"
}

# lcars_config_get — print the JSON value of a top-level string key, with the
# standard JSON escapes un-escaped (\" → ", \\ → \). Mirrors json_str in
# skills/lcars-run/run.sh so both jq-free readers agree on a value written with
# embedded quotes (e.g. a testCommand referencing "${LCARS_TESTS_DIR:-tests}").
# Empty if absent.
lcars_config_get() {
  local config="$1" key="$2"
  [ -f "$config" ] || return 0
  sed -En "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$config" \
    | head -1 \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# lcars_config_set_string — overwrite the JSON value of ONE top-level key with a
# (JSON-escaped) string, preserving all text outside the targeted value.
# Unlike lcars_config_merge this DELIBERATELY
# replaces an existing value — use it only for targeted, fingerprinted migrations.
lcars_config_set_string() {
  _lcars_config_json set-string "$1" "$2" "$3" ""
}

_lcars_config_json() {
  "${LCARS_PYTHON_BIN:-python3}" "$(dirname "${BASH_SOURCE[0]}")/config.py" "$@"
}
# ===========================================================================
# THE CLONE FINGERPRINT AND THE MISSION-ID MINTER  (S196, half A, leg 4)
# ===========================================================================
#
# WHAT WAS MEASURED (S191's live two-laptop capstone, 2026-09-09). Mission ids
# were `lcars-YYYYMMDD-NNN`, and NNN was counted by scanning ONE CLONE's
# `.git/lcars/missions/`. That number is generated from purely local
# information, yet the id it produces is a GLOBALLY SHARED NAME: it is the
# mission DIRECTORY the CLI addresses, it is the git BRANCH `lcars/<id>` on the
# SHARED remote, and it was adopt's lookup key. Two laptops filing against one
# repo on one day minted the IDENTICAL id. Adopting the colliding issue matched
# the wrong mission, reported "refreshed an existing local mission", overwrote a
# SHIPPED mission's merge record in place, and reused its MERGED branch.
#
# The round doc froze the id FORMAT. The captain UNFROZE it on 2026-09-09, after
# being shown the refusal-only alternative, and chose to WIDEN THE NAME:
#
#     lcars-YYYYMMDD-NNN-<fp>        fp = 4 lowercase hex, PER CLONE
#
# THE THREE RULES THIS CODE EXISTS TO KEEP:
#
#   1. THE FINGERPRINT IS PER CLONE, NOT PER MISSION, NOT PER MACHINE, NOT PER
#      USER, NOT PER PATH. It is minted ONCE as a UUID4 and stored in the
#      clone's own `.git/lcars/config.json` — which git never carries, so a
#      clone can only ever hold its own. Deriving it from the login, the
#      hostname or the repo path would be cheaper and WRONG: two clones of one
#      repo, on one machine, by one user, share all three and must still
#      differ. (`git clone` twice into ~/a and ~/b is a normal thing to do.)
#
#   2. EXISTING IDS ARE NEVER RE-MINTED. Nothing migrates, nothing is renamed.
#      Every `lcars-YYYYMMDD-NNN` already on disk keeps resolving, running,
#      rendering and adopting exactly as it did — which is why the SEQUENCE
#      SCAN below is the most dangerous line in this file. It used to read
#      `${d##*-}`: the text after the LAST hyphen. On `…-001-a3f4` that is the
#      FINGERPRINT, and `$((10#a3f4))` is a fatal arithmetic error, so the very
#      first mission a widened clone filed would have broken every mint after
#      it. The scan now strips the KNOWN prefix `lcars-<date>-`, takes the field
#      up to the next hyphen, and SKIPS anything that is not all digits — so a
#      mixed directory (legacy + fingerprinted + hand-made junk) sequences
#      correctly and can never crash.
#
#   3. LAZY ACQUISITION, NEVER A CAPTAIN CHORE. Every repo already initialised
#      on this machine — and every clone `lcars adopt` seeds — has no
#      fingerprint. It acquires one on first use, silently. `lcars init` seeds
#      it up front and `lcars update` backfills it, but neither is required.
#
# The `lcars adopt` refusals from leg 1 (id collision, branch collision) STAY.
# They are the backstop for LEGACY ids minted before this change; this code
# stops them firing for NEW missions, it does not make them unnecessary.

# The fingerprint's length. Four hex chars is a 65 536-value space — a coin-flip
# birthday collision needs ~300 clones of one repo, and the handful of laptops
# this protocol is for are nowhere near it. It also keeps the id short enough to
# read on a board card and to type as a partial-id selector. And a collision is
# not silent even then: `lcars adopt`'s leg-1 refusals are still standing behind
# this, and they fire on exactly that case.
LCARS_CLONE_FP_LEN=4

# _lcars_valid_clone_id — 0 iff the argument is a 32-char lowercase hex string.
_lcars_valid_clone_id() {
  case "${1:-}" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#1}" -eq 32 ]
}

# _lcars_new_clone_id — a fresh 32-hex clone identity. UUID4 is the honest
# source (genuinely random, no hidden dependence on user/host/path); the two
# fallbacks exist only so a repo without python3 or /dev/urandom still gets an
# id rather than an error.
_lcars_new_clone_id() {
  local v=""
  v="$("${LCARS_PYTHON_BIN:-python3}" -c 'import uuid; print(uuid.uuid4().hex)' 2>/dev/null)"
  _lcars_valid_clone_id "$v" || v=""
  if [ -z "$v" ]; then
    v="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    _lcars_valid_clone_id "$v" || v=""
  fi
  if [ -z "$v" ]; then
    v="$(printf '%08x%08x%08x%08x' \
          "$(( (RANDOM << 15) ^ RANDOM ))" "$$" \
          "$(date +%s 2>/dev/null || echo 0)" "$(( (RANDOM << 15) ^ RANDOM ))")"
    v="$(printf '%s' "$v" | tr 'A-Z' 'a-z' | cut -c1-32)"
  fi
  printf '%s' "$v"
}

# _lcars_config_insert_head_key <config> <key> <string-value>
#   Insert a top-level string key as the FIRST key of the object, preserving
#   every other byte of the file.
#
# The shared writer handles both one-line and pretty-printed configs.
_lcars_config_insert_head_key() {
  lcars_config_set_or_add_string "$@"
}

# lcars_clone_id <config-path> [--dry-run] — this clone's durable 32-hex identity.
#
# With --dry-run, resolve the same identity without persisting it.
# Read it, or mint and PERSIST it. The canonical home is `cloneId` in the
# clone's config.json (a NEW key, inserted at the TOP of the object per the
# house rule). When there is no config.json yet — a repo mid-setup, or a clone
# `lcars adopt` seeded before `lcars init` ran — it falls back to a plain
# `<lcars-dir>/clone-id` file beside it, and a later config.json ADOPTS that
# value rather than minting a second one. Either way the answer is stable for
# the life of the clone, which is the only property the id depends on.
lcars_clone_id() {
  local config="${1:-}" dir side cid="" from_config=""
  [ -n "$config" ] || { _lcars_new_clone_id; return 0; }
  dir="$(dirname "$config")"
  side="$dir/clone-id"

  if [ -f "$config" ]; then
    from_config="$(lcars_config_get "$config" cloneId)"
    _lcars_valid_clone_id "$from_config" && cid="$from_config"
  fi
  if [ -z "$cid" ] && [ -f "$side" ]; then
    local fromside; fromside="$(tr -d '[:space:]' <"$side" 2>/dev/null)"
    _lcars_valid_clone_id "$fromside" && cid="$fromside"
  fi
  [ -n "$cid" ] || cid="$(_lcars_new_clone_id)"
  if [ "${2:-}" = "--dry-run" ]; then
    printf '%s' "$cid"
    return 0
  fi

  if [ ! -f "$config" ]; then
    [ -d "$dir" ] && { printf '%s\n' "$cid" >"$side" 2>/dev/null || true; }
  elif [ "$from_config" != "$cid" ]; then
    if ! lcars_config_has_key "$config" cloneId; then
      _lcars_config_insert_head_key "$config" cloneId "$cid" 2>/dev/null || true
    elif [ "$(grep -c '^[[:space:]]*"cloneId"[[:space:]]*:' "$config" 2>/dev/null)" = "1" ]; then
      # The key owns its own line — lcars_config_set_string's documented
      # precondition. Repairing an unusable value in place is safe here.
      lcars_config_set_string "$config" cloneId "$cid" 2>/dev/null || true
    else
      # The key is PRESENT, UNUSABLE, and shares its line with other keys (a
      # hand-edited one-line config). lcars_config_set_string would rewrite the
      # whole line and take the neighbouring keys with it, so it is never
      # reached for: the value goes to the bridge file instead, which the read
      # above prefers over an invalid config value. Stability without a risk of
      # corrupting a file we did not write.
      [ -d "$dir" ] && { printf '%s\n' "$cid" >"$side" 2>/dev/null || true; }
    fi
  fi
  printf '%s' "$cid"
}

# lcars_clone_fingerprint <config-path> — the SHORT per-clone tag that goes in
# a mission id. Empty only when there is no id to be had at all.
lcars_clone_fingerprint() {
  local cid; cid="$(lcars_clone_id "${1:-}")"
  [ -n "$cid" ] || return 0
  printf '%s' "$(printf '%s' "$cid" | cut -c1-"$LCARS_CLONE_FP_LEN")"
}

# lcars_mint_mission_id <missions-dir> <YYYYMMDD> [fingerprint]
#   The ONE minter. All three mint sites (lcars-file's two lanes and lcars-log)
#   call this so the sequence scan cannot drift between them. An EMPTY
#   fingerprint mints the pre-S196 shape — the degraded answer, never the
#   default.
lcars_mint_mission_id() {
  local mdir="$1" date="$2" fp="${3:-}"
  local max=0 d n
  shopt -s nullglob
  for d in "$mdir"/lcars-"$date"-*; do
    n="${d##*/}"          # basename:            lcars-<date>-NNN[-<fp>]
    n="${n#lcars-$date-}" # strip the KNOWN prefix:     NNN[-<fp>]
    n="${n%%-*}"          # the sequence field alone:   NNN
    case "$n" in ''|*[!0-9]*) continue ;; esac   # junk in missions/ is skipped
    n=$((10#$n))
    [ "$n" -gt "$max" ] && max="$n"
  done
  shopt -u nullglob
  if [ -n "$fp" ]; then
    printf 'lcars-%s-%03d-%s' "$date" "$((max + 1))" "$fp"
  else
    printf 'lcars-%s-%03d' "$date" "$((max + 1))"
  fi
}

# lcars_config_merge — write config.json preserving existing keys.
#
# Args:
#   $1  path to config.json (may not yet exist)
#   $2  newline-separated "key=jsonvalue" desired pairs, in the canonical key
#       order. Each jsonvalue is already JSON-formatted (quoted string, number,
#       null) by the caller.
#   $3  optional --dry-run: emit the merged JSON to stdout without writing.
#
# For each desired key: if the existing config already has it, the EXISTING raw
# JSON value is preserved; otherwise the supplied default jsonvalue is written.
# Values are parsed in full, serialized on one line, and validated before an
# atomic replacement. Invalid existing settings are refused, never repaired
# implicitly or partly replaced.
# Keys present in the file but not in the desired list are dropped (the desired
# list is the canonical schema) — but every current key IS in the schema, so in
# practice nothing the captain set is lost.
#
# Sets for the caller to report on:
#   LCARS_CONFIG_ADDED_KEYS    space-separated keys newly added this write
#   LCARS_CONFIG_PRESENT_KEYS  space-separated keys preserved from existing
lcars_config_merge() {
  local config="$1" desired="$2"
  LCARS_CONFIG_ADDED_KEYS=""
  LCARS_CONFIG_PRESENT_KEYS=""
  local result
  result="$(_lcars_config_json merge "$config" "$desired" "${3:-}")" || return 1
  LCARS_CONFIG_ADDED_KEYS="${result%%$'\n'*}"
  result="${result#*$'\n'}"
  LCARS_CONFIG_PRESENT_KEYS="${result%%$'\n'*}"
  [ "${3:-}" != "--dry-run" ] || printf '%s\n' "${result#*$'\n'}"
  return 0
}

# ---------------------------------------------------------------------------
# WORKTREE PROVISIONING DEFAULT (ecosystem detection)
# ---------------------------------------------------------------------------
# `lcars run` provisions each Stage's isolated git worktree by running the
# config's `worktreeSetupCommand` ONCE with the worktree as CWD (via `bash -c`).
# A fresh worktree shares the object store but NOT the main checkout's
# uncommitted/gitignored installed deps (node_modules, venv), so a Stage that
# needs the test runner installed would otherwise break. This emits a sensible
# per-ecosystem default that REUSES what the main checkout already has —
# symlinking its node_modules (root + each pnpm-workspace package) into the
# worktree, falling back to an OFFLINE, lockfile-frozen install when the main
# checkout has none. No network, no special cache.
#
# Shared by BOTH `lcars init` (seed on first setup) and `lcars update` (backfill
# the key into an older config) so the default can never drift between them.
# Reads $TOPLEVEL (the repo root) from the caller's environment, exactly like
# init's detect_test_cmd.
#
# IMPORTANT: the emitted string is a SINGLE shell command whose `$MAIN` / `$(…)`
# must be evaluated AT PROVISION TIME in the worktree — NOT now. It is therefore
# emitted as a single-quoted literal (no expansion here); the caller stores it
# via lcars_json_escape (valid JSON) and the runtime `bash -c` expands it. Empty
# when LCARS can't infer a safe default (Python/Rust/Go/Make/bash/none) — the
# provisioner then warns and skips rather than running a command that errors.
detect_worktree_setup_cmd() {
  # JS/TS: symlink the main checkout's node_modules (root + every pnpm workspace
  # package's own, which nests its .bin), else an offline lockfile-frozen install.
  if [ -f "$TOPLEVEL/package.json" ]; then
    local install lock
    # S207 — A LOCKFILE-FROZEN INSTALL NEEDS A LOCKFILE. `npm ci` does not fall
    # back when `package-lock.json` is absent: it ERRORS ("can only install
    # packages when your package.json and package-lock.json are in sync"), and
    # the seeded command was reaching for it in EVERY JS repo. A live run logged
    # four provisioning failures from exactly this, in a repo whose lockfile is
    # gitignored. `pnpm install --frozen-lockfile` fails the same way, and the
    # pnpm arm is taken by a bare `pnpm-workspace.yaml` too — so a workspace
    # that has never been installed took an arm that could not succeed.
    # The frozen form is kept wherever the lockfile is really there (it is the
    # reproducible install, and the whole point of the arm); without one we seed
    # the install that WORKS. yarn needs no guard: only `yarn.lock` takes its arm.
    if [ -f "$TOPLEVEL/pnpm-lock.yaml" ] || [ -f "$TOPLEVEL/pnpm-workspace.yaml" ]; then
      lock='pnpm-lock.yaml'
      if [ -f "$TOPLEVEL/pnpm-lock.yaml" ]; then
        install='pnpm install --frozen-lockfile --prefer-offline --silent'
      else
        install='pnpm install --prefer-offline --silent'
      fi
    elif [ -f "$TOPLEVEL/yarn.lock" ]; then
      install='yarn install --immutable'
      lock='yarn.lock'
    else
      lock='package-lock.json'
      if [ -f "$TOPLEVEL/package-lock.json" ]; then
        install='npm ci'
      else
        install='npm install'
      fi
    fi
    # THE LOCKFILE GUARD comes first: reusing the main checkout's node_modules is
    # only correct while this worktree wants the SAME dependencies. A ticket that
    # changes the lockfile makes the shared install the WRONG set by definition,
    # and symlinking it would test the ticket against packages its own commit
    # replaced — a failure no committed change could ever repair, which then reads
    # downstream as "the implementation is not present". Diverged ⇒ real install.
    #
    # find symlinks EVERY node_modules that is not nested inside another one
    # (-prune halts the descent at each match), recreating its path relative to
    # the main checkout inside the worktree. Generic across npm/yarn/pnpm.
    printf '%s\n' 'MAIN="$(git rev-parse --path-format=absolute --git-common-dir)"; MAIN="${MAIN%/.git}"; if [ -d "$MAIN/node_modules" ] && [ -f '"$lock"' ] && [ -f "$MAIN/'"$lock"'" ] && ! cmp -s '"$lock"' "$MAIN/'"$lock"'"; then '"$install"'; elif [ -d "$MAIN/node_modules" ]; then find "$MAIN" -path "$MAIN/.git" -prune -o -name node_modules -type d -prune -print | while IFS= read -r nm; do rel="${nm#$MAIN/}"; mkdir -p "$(dirname "$rel")"; ln -snf "$nm" "$rel"; done; else '"$install"'; fi'
    return
  fi
  # Python and everything else: no single offline-safe string we can guarantee —
  # emit empty and let the provisioner warn (never emit a command that errors).
  echo ""
}

# ---------------------------------------------------------------------------
# TEST-COMMAND DETECTION (S146: moved here from init.sh so the readiness
# verdict below — shared by init, update, status AND the viewscreen daemon —
# can consult the SAME detector. Byte-identical logic; init.sh still calls it.)
# ---------------------------------------------------------------------------
# The Implement red gate (BUG-007) runs testCommand to prove the fail-first
# suite FAILS before the Implementer runs — scoped to $LCARS_TESTS_DIR. We emit
# a $LCARS_TESTS_DIR-honouring default per ecosystem. Reads $TOPLEVEL from the
# caller's environment. Empty when nothing can be detected.
# The vitest test command must RELATIVIZE $LCARS_TESTS_DIR to the runner's cwd
# (vitest's positional filter is package-root-relative; the gate exports an
# ABSOLUTE path) — stripping a leading "$PWD/" turns it package-relative.
VITEST_RELATIVIZING_CMD='npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'
#
# S148 — QUOTE THE SCOPE. Every seeded command interpolates $LCARS_TESTS_DIR as
# the positional scope, and the gate exports it as an ABSOLUTE path. Interpolated
# UNQUOTED, that path WORD-SPLITS on IFS whitespace the moment the repo is checked
# out somewhere containing a space or a tab: `node --test ${LCARS_TESTS_DIR:-}`
# with a scope of `/x/sp test/src/calc.test.js` hands the runner TWO arguments,
# `/x/sp` and `test/src/calc.test.js`, and the flip-flop proof gate then FALSE-
# FAILS a perfectly honest ticket purely because of WHERE the repo lives (which
# bounces it to a fresh worker up to 3 times and then parks it awaiting-human).
#
# The two quoting shapes below are NOT interchangeable, and which one an arm takes
# is decided by its DEFAULT, not by taste:
#   `"${LCARS_TESTS_DIR:-<default>}"`   when the default is NON-EMPTY (pytest's
#       `.`, the bash runner's `tests`) — always exactly one argument either way.
#   `${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}`  when the default is EMPTY. Writing
#       `"${LCARS_TESTS_DIR:-}"` here would quote it but ALSO hand the runner an
#       EMPTY positional argument when the scope is unset — a different run (mocha
#       errors on it, npm forwards it to the script), i.e. a behaviour change
#       smuggled in under a quoting fix. `:+` keeps "no scope ⇒ no argument"
#       byte-for-byte and is the idiom VITEST_RELATIVIZING_CMD above already uses.
# Every seeded command is otherwise unchanged; the only delta is the quoting.
# `lcars update` migrates the already-persisted unquoted strings (update.sh).

# detect_workspace_runner — name the local test runner a monorepo actually uses,
# so the workspace fallback emits a runner-SCOPED command instead of a bare
# `npm test` fan-out. Inspects (in order) a runner config at the workspace root,
# the pnpm lockfile, then every sub-package's package.json devDependencies.
# Echoes vitest|jest|mocha (empty when none found).
detect_workspace_runner() {
  local r
  for r in vitest jest mocha; do
    ls "$TOPLEVEL/$r.config".* >/dev/null 2>&1 && { echo "$r"; return; }
  done
  for r in vitest jest mocha; do
    grep -qs -- "$r" "$TOPLEVEL/pnpm-lock.yaml" 2>/dev/null && { echo "$r"; return; }
  done
  for r in vitest jest mocha; do
    grep -rqs --include='package.json' --exclude-dir='node_modules' -- "\"$r\"" "$TOPLEVEL" 2>/dev/null \
      && { echo "$r"; return; }
  done
  echo ""
}

# detect_dotnet_test_projects (S147) — echo every TEST project in the repo, one
# $TOPLEVEL-relative *.csproj path per line (LC_ALL=C sorted, so the "exactly
# one" decision is deterministic). A project counts as a TEST project when it
# either references `Microsoft.NET.Test.Sdk` (the real signal — every xunit /
# nunit / mstest template adds it) OR carries the `*Tests*.csproj` naming
# convention (a hand-rolled project that inherits the ref from Directory.Build
# .props still reads as a test project). `bin/` and `obj/` are EXCLUDED: a build
# leaves copies of the csproj under obj/, and counting those would make every
# already-built repo look "ambiguous". Reads $TOPLEVEL like its siblings.
detect_dotnet_test_projects() {
  find "$TOPLEVEL" -type d \( -name bin -o -name obj -o -name .git \) -prune -o \
       -type f -name '*.csproj' -print 2>/dev/null \
  | LC_ALL=C sort \
  | while IFS= read -r p; do
      [ -n "$p" ] || continue
      dotnet_csproj_is_test "$p" && printf '%s\n' "${p#"$TOPLEVEL/"}"
    done
}

# dotnet_csproj_is_test — is this *.csproj a TEST project? It either references
# `Microsoft.NET.Test.Sdk` (the real signal — every xunit / nunit / mstest
# template adds it) or carries the `*Tests*.csproj` naming convention (a
# hand-rolled project inheriting the ref from Directory.Build.props still reads
# as a test project). The ONE predicate both the marker probe and the seed
# enumeration use, so they can never disagree about what a test system is.
# The Test.Sdk match is CASE-INSENSITIVE: NuGet package ids are, so a hand-
# written `microsoft.net.test.sdk` reference is a perfectly valid test project
# and used to fall through to the greenfield "no test systems found" voice.
dotnet_csproj_is_test() { # abs csproj path
  case "${1##*/}" in *Tests*.csproj) return 0 ;; esac
  grep -qi 'Microsoft\.NET\.Test\.Sdk' "$1" 2>/dev/null
}

# detect_dotnet_markers (S147) — does this repo look like a .NET repo at all?
# 0 = yes. TWO rules, deliberately different in strength:
#
#   TOP LEVEL — any *.csproj / *.sln / *.slnx counts, whatever it contains.
#     This is the pre-147 rule, kept BYTE-IDENTICAL: a repo whose root is a C#
#     project is a C# repo, full stop.
#
#   BELOW IT — a bounded scan that counts a project ONLY when it is an actual
#     TEST SYSTEM. The recursion exists for one reason: the single most common
#     C# layout on earth, `dotnet new xunit -o MyApp.Tests`, puts the only
#     project ONE DIRECTORY DOWN and writes no root solution, so a top-level-only
#     glob read it as stack:unknown and told the captain the repo was greenfield.
#     Counting *any* nested csproj overshot badly: a vendored C# sample or a
#     `tools/` helper flipped a healthy js/python/rust repo to `ambiguous` and
#     REMOVED its working seed — and the verdict contradicted itself, offering
#     one candidate while insisting it would not choose between them. A bare
#     .csproj with no test SDK reference is not a test system, so it is not a
#     signal; a nested *Tests* project still is. Nested solutions do not count
#     at all (a .sln says nothing about tests).
#
# Bounded and cheap: `$DOTNET_MARKER_MAXDEPTH`, `bin`/`obj`/`.git`/`node_modules`
# pruned (a build leaves csproj copies under obj/), stops at the first hit.
#
# WHERE EACH SCAN LOOKS, stated once, because the two scans deliberately differ:
#   • THIS probe is bounded, because it runs on EVERY repo — including every
#     js/python/rust one that will never be .NET — on every detection and every
#     board render. It is a hot path and must stay cheap.
#   • detect_dotnet_test_projects is EXHAUSTIVE (no maxdepth), because it runs
#     only once a repo is already known to be .NET, and a solution may legitimately
#     nest its test projects deeper than this bound. Bounding it too would make a
#     repo detect as dotnet and then seed nothing, which is strictly worse.
# The two agree on WHAT a test system is (dotnet_csproj_is_test, the single
# predicate); they differ on WHERE only, for the reason above.
#
# LEDGERED (recorded, not fixed): a test project deeper than the bound, in a repo
# with no top-level marker, still reads as greenfield — the surface asserts
# absence ("no test systems found") rather than admitting it only looked
# `$DOTNET_MARKER_MAXDEPTH` levels down. Raising the bound trades that for a
# slower scan on every board render; revisit with a real repo that needs it.
#
# KEEP IN STEP with `_DETECT_MARKER_GLOBS`/`_DETECT_MARKER_RGLOBS` in
# web/lcars_serve/local_adapter.py — the board's memo must move when these do,
# or CLI and board drift apart (the S146 D2 contract).
DOTNET_MARKER_MAXDEPTH=3
detect_dotnet_markers() {
  local f p
  for f in "$TOPLEVEL"/*.csproj "$TOPLEVEL"/*.sln "$TOPLEVEL"/*.slnx; do
    [ -e "$f" ] && return 0
  done
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    dotnet_csproj_is_test "$p" && return 0
  done <<DN_MARK
$(find "$TOPLEVEL" -maxdepth "$DOTNET_MARKER_MAXDEPTH" \
    -type d \( -name bin -o -name obj -o -name .git -o -name node_modules \) -prune -o \
    -type f -name '*.csproj' -print 2>/dev/null)
DN_MARK
  return 1
}

# ---------------------------------------------------------------------------
# The per-stack seed ARMS (S147). detect_test_cmd used to be one long if-chain;
# each ecosystem's rule now lives in its own `_dtc_<stack>` helper and the chain
# just walks them IN THE SAME ORDER, so behaviour is unchanged for every stack.
# The split exists so ONE stack's rule can be asked in isolation
# (detect_test_cmd_for_stack) — which is how an AMBIGUOUS repo can offer the
# captain a real command per candidate instead of hiring a discovery worker.
#
# CONTRACT: an arm returns 0 when it CLAIMS the repo (stdout = the command,
# possibly EMPTY when that stack is internally ambiguous and must not be
# guessed) and 1 when it does not apply, letting the chain continue. That
# distinction is what lets dotnet-with-no-test-project fall THROUGH to the
# generic Makefile / tests/run.sh fallbacks it always used to reach.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# THE INERT-DECLARATION FILTER (S299)
# ---------------------------------------------------------------------------
# MEASURED, 2026-10-15: an implementor bounced by the post-hoc gate for "no test
# command LCARS can detect at the repo root" came back having written a
# `tox.ini` whose entire contents were `[tox]` and an empty `envlist =`. It runs
# nothing. That particular file detects nothing here either (measured: a lone
# inert tox.ini has always returned EMPTY, because the python arm claims a
# RUNNER and not a marker), but it named the class: an arm can claim a repo on
# an artifact that merely LOOKS like test configuration, and three of them did.
#
# THE RULE IS THE DOTNET AND PYTHON ARMS' RULE, ONE STEP FURTHER ON. Those arms
# stopped claiming on the mere PRESENCE of a marker; these helpers stop claiming
# on an artifact whose own runnable content is EMPTY. Nothing else changes: an
# arm that would have emitted a command still emits exactly that command.
#
# THE DIRECTION EVERY CHECK ERRS IN IS *ACCEPT*, DELIBERATELY AND WITHOUT
# EXCEPTION. A false negative here is strictly worse than the decoy it would
# catch: a legitimate repo whose runner LCARS stops finding is refused at the
# filing gate and a real mission dies, where a decoy that slips through is
# caught downstream by the probe's zero-collected outcome and by the flip-flop
# gate. So each helper answers "is this artifact PROVABLY a no-op?" and returns
# "no" — accept — for everything it cannot settle: anything naming a runner,
# anything whose commands it does not recognise, anything it cannot read, and
# any file shape that could be hiding a recipe (a Makefile with an `include`,
# a pattern rule, a `.DEFAULT`).
#
# NOT EXECUTED, BY CHOICE. `make -n test` would ask make itself (and agrees:
# "Nothing to be done for `test'"), but `-n` still RUNS sub-makes and evaluates
# `$(shell …)`, and detection must stay side-effect-free and work on a machine
# where the runner is not installed — the same determinism the python arm's
# comment argues for. These are narrow STRUCTURAL reads of the one inert shape
# each, on syntax the tool itself defines.
#
# WHAT THEY CANNOT SEE: a recipe that runs a real command which happens to do
# nothing (`test:` → `@echo ok`, a `tests/run.sh` that loops over an empty
# directory, `npm test` → a script that exits before collecting); a runner
# installed but mis-wired; a suite that collects zero tests. Those are the
# PROBE's question (run_probe's `zero-collected`), not detection's, and this
# filter deliberately does not reach for them.

# The shell no-ops. A segment whose first word is one of these runs no tests;
# ANY other first word means we cannot tell, and the artifact is accepted.
#
# S299 fix round 1 — `set` and `cd` joined the list. Both were already treated
# as no-ops by the run.sh arm (which DELETED `set` lines before looking) and
# neither can run a test on its own; and because a segment list is only
# "provably inert" when EVERY segment is a no-op, adding them can only matter
# where nothing else runs either. `set -e; ./suite.sh` still ACCEPTS on
# `./suite.sh`; `cd src && go test ./...` accepts on the runner token.
_DTC_NOOP_WORDS='echo printf true false : exit set cd'

# ---------------------------------------------------------------------------
# _dtc_noop_only — THE ONE JUDGEMENT, shared by all three arms (S299 fix 1)
# ---------------------------------------------------------------------------
# 0 when <body> — a package.json `test` script, a Makefile `test:` recipe, or a
# `tests/run.sh` body — PROVABLY runs no commands that could run a test. 1
# (ACCEPT) for everything it cannot settle.
#
# WHY IT IS ONE FUNCTION. It shipped as the npm arm's private logic and the
# other two arms asked a weaker question ("is there any command at all?"), so
# the SAME string got two verdicts: `"test": "true"` was refused while a
# Makefile recipe of `true` was accepted. Three copies could not help diverging
# again, so there is exactly one copy and the three arms differ only in how they
# EXTRACT a body and how they WORD the refusal. Any future rule lands here and
# lands on all three at once.
#
# THE DIRECTION IT ERRS IN IS ACCEPT, at every branch:
#   * a RUNNER TOKEN anywhere is a full stop — accept, whatever else is there;
#   * a command substitution or a backtick can run a command this read cannot
#     see (`: $(./suite.sh)` really does run the suite) — accept;
#   * a process substitution (`>(…)`, `<(…)`) likewise — accept;
#   * any segment whose first word is not on the tiny no-op list — accept.
# Only a body in which EVERY segment is a known no-op is refused.
#
# PLAIN REDIRECTION IS NOT A REASON TO ACCEPT, and that is the one tightening
# this round makes to the shared rule. The npm arm bailed on any `>` or `<` on
# the grounds that "a redirection can put a command where this cannot see it" —
# which is true of `>(…)` and of `$(…)`, and false of `>&2`, `2>&1`, `> out.log`
# and `< fixture.txt`: a redirection TARGET is a file or a descriptor, never a
# command. Keeping the blanket bail meant `echo "no tests configured" >&2` was
# accepted while the identical line without `>&2` was refused. So the two
# process-substitution forms still bail, and a descriptor redirection is merely
# NEUTRALISED before splitting — `>&2` carries an `&` that is not a command
# separator, and splitting on it invented a phantom segment (`2`) whose first
# word is unknown, which is exactly how the decoy got in.
#
# IT IS NOT ASKED "is the body empty?" — an empty body is each arm's own
# question, because each one has a better sentence for it.
_dtc_noop_only() { # body → 0 provably inert, 1 accept
  local body="$1"
  printf '%s' "$body" | grep -qE "$LCARS_TEST_RUNNER_TOKENS" && return 1
  case "$body" in *'$('*|*'`'*|*'>('*|*'<('*) return 1 ;; esac
  # EVERY segment must be a known no-op. The split is on `;`, `|` and `&`, which
  # covers `&&` and `||` too (they yield an empty middle segment, skipped) — and
  # it must happen in awk rather than in a shell loop fed by a heredoc, because
  # an unquoted heredoc eats the backslash-newlines a multiline `sed` script
  # needs and silently deletes the separators instead of splitting on them. That
  # bug called `echo x | node t.js` a no-op; `node` is now seen.
  printf '%s\n' "$body" | awk -v noops="$_DTC_NOOP_WORDS" '
    BEGIN { n = split(noops, w, " "); for (i = 1; i <= n; i++) ok[w[i]] = 1 }
    {
      line = $0
      # `>&2`, `2>&1`, `1>&-` — a descriptor redirection, not a separator.
      gsub(/[0-9]*[<>]+&[0-9-]*/, " ", line)
      m = split(line, seg, /[;|&]/)
      for (i = 1; i <= m; i++) {
        cmd = seg[i]; sub(/^[ \t]+/, "", cmd); sub(/[ \t].*$/, "", cmd)
        if (cmd != "" && !(cmd in ok)) live = 1
      }
    }
    END { exit live ? 1 : 0 }
  '
}

# _dtc_first_cmd — the first non-blank line of <body>, trimmed and clipped, so a
# refusal can QUOTE what it found instead of describing it in the abstract.
_dtc_first_cmd() {
  printf '%s\n' "$1" | awk '
    /[^ \t]/ { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
               if (length($0) > 60) $0 = substr($0, 1, 57) "..."
               printf "%s", $0; exit }'
}

# _dtc_inert_npm_test — the root package.json's `test` script provably runs
# nothing. Prints the reason and returns 0; silent 1 otherwise.
_dtc_inert_npm_test() {
  local pj="$TOPLEVEL/package.json" raw body
  [ -f "$pj" ] && [ -r "$pj" ] || return 1
  # The value WITH its escapes intact — `[^"\]|\\.` so a `\"` inside the script
  # cannot truncate it. A truncated body is how a lazy read calls
  # `echo "x" && jest` a no-op.
  raw="$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"([^"\]|\\.)*"' "$pj" 2>/dev/null | head -1)"
  [ -n "$raw" ] || return 1
  body="${raw#*:}"
  body="${body#"${body%%[^[:space:]]*}"}"
  body="${body#\"}"; body="${body%\"}"
  body="$(printf '%s' "$body" | sed 's/\\"/"/g; s/\\\\/\\/g')"
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    printf 'a package.json `test` script that is EMPTY — `npm test` runs no tests and exits 0'
    return 0
  fi
  _dtc_noop_only "$body" || return 1
  printf 'a package.json `test` script that names no test runner and only runs shell no-ops (`%s`) — it runs no tests' "$body"
}

# _dtc_make_recipe_prefix — the character that introduces a recipe line in
# <makefile>. A TAB unless the file sets `.RECIPEPREFIX` (GNU Make >= 3.82),
# which is a legal, working Makefile this detector used to misread as having no
# recipe at all — it looked for tabs and nothing else, so a `>`-prefixed recipe
# was invisible and a real runner was refused. The last assignment wins, which
# is make's own rule for a simple variable read top-to-bottom.
#
# Prints the character, or EMPTY for "a tab" (also what an explicitly empty
# `.RECIPEPREFIX =` means to make: the default comes back).
_dtc_make_recipe_prefix() {
  awk '
    /^[ \t]*\.RECIPEPREFIX[ \t]*[:+?]?=/ {
      v = $0
      sub(/^[ \t]*\.RECIPEPREFIX[ \t]*[:+?]?=/, "", v)
      sub(/^[ \t]+/, "", v)
      p = substr(v, 1, 1)
    }
    END { printf "%s", p }
  ' "$1" 2>/dev/null
}

# _dtc_inert_make_test — the Makefile's `test:` target cannot run a test.
# Prints the reason and returns 0; silent 1 (ACCEPT) otherwise.
#
# THREE SHAPES, THREE SENTENCES (S299 fix round 1 — the message used to claim
# "no recipe" about two files that plainly had one):
#   norecipe  no recipe and no prerequisites → `make test` prints "Nothing to be
#             done for `test'." and exits 0 (verified by running it).
#   spaces    a recipe indented with SPACES instead of a tab → real make refuses
#             the file outright: "*** missing separator (did you mean TAB
#             instead of 8 spaces?). Stop." Refusing is right; saying "no
#             recipe" was not, because the fix is one keystroke and naming it
#             is the whole value of the message.
#   noop      a recipe that runs only shell no-ops (`@echo "no tests yet"`,
#             `true`, `:`, `exit 0`) → judged by `_dtc_noop_only`, the SAME
#             function that judges the npm script, so the same string can no
#             longer get two verdicts.
# Prerequisites, or any recipe line this read cannot prove inert, ACCEPT.
_dtc_inert_make_test() {
  local mf="$TOPLEVEL/Makefile" pfx kind cmds out
  [ -f "$mf" ] && [ -r "$mf" ] || return 1
  grep -q '^test:' "$mf" || return 1   # the generic arm's own gate, unchanged
  # A file that pulls rules in, matches any target, or has a default rule may
  # hold a recipe this read cannot see — accept.
  grep -qE '^[[:space:]]*[-s]?include[[:space:]]' "$mf" && return 1
  grep -qE '^(\.DEFAULT|\.DEFAULT_GOAL|[^:[:space:]]*%[^:[:space:]]*):' "$mf" && return 1
  # S299 fix round 1 — a GENERATED rule is also out of sight. A `define` block or
  # an `$(eval …)` can declare `test:` with a recipe this structural read would
  # attribute to the wrong place (the `test:` line inside a `define` body looks
  # exactly like a real target), so the whole file is accepted rather than
  # guessed at. Same family as the `include` bail above, same direction.
  grep -qE '^[[:space:]]*define[[:space:]]|\$\(eval' "$mf" && return 1
  pfx="$(_dtc_make_recipe_prefix "$mf")"
  # A `#` prefix would collide with this read's comment stripping — accept
  # rather than guess.
  [ "$pfx" = '#' ] && return 1
  [ -n "$pfx" ] || pfx="$(printf '\t')"
  out="$(awk -v pfx="$pfx" '
    BEGIN { tab = "\t" }
    /^test[ \t]*::?/ {
      found = 1; inrec = 1
      rest = $0; sub(/^test[ \t]*::?/, "", rest); sub(/#.*$/, "", rest)
      if (rest ~ /[^ \t]/) prereq = 1   # prerequisites, or an inline `; recipe`
      next
    }
    inrec {
      c = substr($0, 1, 1)
      if (c == pfx || c == tab) {       # a recipe line, by make'"'"'s own syntax
        body = $0
        while (substr(body, 1, 1) == pfx || substr(body, 1, 1) == tab) body = substr(body, 2)
        sub(/^[-@+]+/, "", body); sub(/#.*$/, "", body)
        if (body ~ /[^ \t]/) { recipe = 1; cmds = cmds body "\n" }
        next
      }
      if ($0 ~ /^[ \t]*(#|$)/) next     # blanks and comments decide nothing
      # A SPACE-indented line that reads as a command, not as an assignment, a
      # rule or a make directive: this is the "missing separator" file.
      if ($0 ~ /^ +[^ \t]/ && $0 !~ /[:=]/ \
          && $0 !~ /^ +(include|-include|sinclude|ifeq|ifneq|ifdef|ifndef|else|endif|define|endef|export|unexport|override|vpath|undefine)([ \t]|$)/) {
        spaced = 1; next
      }
      inrec = 0
    }
    END {
      if (!found)  { print "accept";  exit 0 }
      if (prereq)  { print "accept";  exit 0 }
      if (recipe)  { printf "noop\n%s", cmds; exit 0 }
      if (spaced)  { print "spaces";  exit 0 }
      print "norecipe"
    }
  ' "$mf" 2>/dev/null)"
  kind="${out%%
*}"
  cmds="${out#*
}"; [ "$cmds" = "$out" ] && cmds=""
  case "$kind" in
    accept)   return 1 ;;
    norecipe) printf 'a Makefile `test:` target with no recipe and no prerequisites — `make test` prints "Nothing to be done" and runs no tests'; return 0 ;;
    spaces)   printf 'a Makefile `test:` target whose recipe is indented with SPACES, not a tab — make refuses the whole file ("missing separator"), so `make test` runs no tests'; return 0 ;;
    noop)
      _dtc_noop_only "$cmds" || return 1
      printf 'a Makefile `test:` target whose recipe names no test runner and only runs shell no-ops (`%s`) — `make test` runs no tests' "$(_dtc_first_cmd "$cmds")"
      return 0 ;;
    *) return 1 ;;
  esac
}

# _dtc_inert_run_sh — tests/run.sh exists but cannot run a test: it holds no
# command at all (only a shebang, comments and blank lines), or every command in
# it is a shell no-op (`true`, `:`, `exit 0`, an `echo` and nothing else).
# Verified by running both shapes: exit 0, nothing run.
#
# S299 fix round 1 — the second half is new, and it is `_dtc_noop_only`, the
# same judgement the npm script gets. `set` lines are no longer DELETED here;
# `set` is on the shared no-op list instead, which is the same answer reached
# in one place rather than two. Prints the reason and returns 0.
_dtc_inert_run_sh() {
  local f="$TOPLEVEL/tests/run.sh" body
  [ -f "$f" ] && [ -r "$f" ] || return 1
  body="$(sed -e '1{/^#!/d
}' -e 's/#.*$//' "$f" 2>/dev/null)"
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    printf 'a tests/run.sh with no commands in it — the file is there but runs no tests'
    return 0
  fi
  _dtc_noop_only "$body" || return 1
  printf 'a tests/run.sh that names no test runner and only runs shell no-ops (`%s`) — it runs no tests' "$(_dtc_first_cmd "$body")"
}

# _dtc_inert_tox — a tox.ini that declares no environment: an empty/absent
# `envlist` AND no `[testenv…]` section, so `tox` has nothing to launch. This is
# the artifact that named the class.
#
# MESSAGE-ONLY, BY CONSTRUCTION: `_dtc_python` does NOT consult it. tox.ini is
# that arm's MARKER, never its command, and a repo carrying an inert tox.ini
# beside a real pytest/unittest layout detects a REAL runner — demoting the
# marker would refuse that repo, which is exactly the false negative this
# session must not ship. So this helper can only change the WORDING of a
# refusal that had already happened.
_dtc_inert_tox() {
  local f="$TOPLEVEL/tox.ini"
  [ -f "$f" ] && [ -r "$f" ] || return 1
  grep -qE '^[[:space:]]*\[testenv' "$f" && return 1
  grep -qE '^[[:space:]]*envlist[[:space:]]*=[[:space:]]*[^[:space:]]' "$f" && return 1
  # tox.ini doubles as a config file for other tools; a `[pytest]` table there
  # is a real declaration and the python arm already reads it.
  grep -qE '^[[:space:]]*\[(pytest|tool:pytest|flake8|coverage)' "$f" && return 1
  printf 'a tox.ini that declares no environment to run — an empty `envlist` and no `[testenv]` section, so `tox` has nothing to launch'
}

# detect_inert_test_config — WHY the repo root's test configuration, such as it
# is, cannot be run. Prints one phrase per inert artifact found (joined with
# "; ") and returns 0; silent 1 when there is nothing to explain.
#
# This is the MESSAGE half of the filter, kept as its own entry point rather
# than as a global the arms set: `detect_test_cmd` is called in a command
# substitution everywhere, so a global could never reach its caller. The gate
# asks this second, once detection has come back empty — see
# `greenfield_inert_why` in skills/lcars-run/run.sh.
detect_inert_test_config() {
  local out="" leg r
  for leg in npm_test make_test run_sh tox; do
    if r="$("_dtc_inert_$leg")"; then out="${out:+$out; }$r"; fi
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

_dtc_js() {
  [ -f "$TOPLEVEL/package.json" ] && grep -q '"test"[[:space:]]*:' "$TOPLEVEL/package.json" || return 1
    # Monorepo (a pnpm workspace, or a "workspaces" field): a bare `npm test` /
    # `pnpm -r test` here FANS OUT across every package, so the red gate can never
    # scope itself to the touched package's quarantined tests. Prefer a command
    # scoped to the local runner that STILL honours $LCARS_TESTS_DIR — LCARS points
    # the var at the touched package (it knows it from the plan/manifests). When the
    # root "test" script doesn't name the runner, DETECT it from the sub-packages
    # (lockfile / config / devDependencies) rather than emitting a fan-out.
    if [ -f "$TOPLEVEL/pnpm-workspace.yaml" ] || grep -q '"workspaces"[[:space:]]*:' "$TOPLEVEL/package.json"; then
      local script runner
      script="$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$TOPLEVEL/package.json" | head -1)"
      case "$script" in
        *vitest*) echo "$VITEST_RELATIVIZING_CMD";              return ;;
        *jest*)   echo 'npx jest ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';         return ;;
        *mocha*)  echo 'npx mocha ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';        return ;;
        *)
          runner="$(detect_workspace_runner)"
          case "$runner" in
            vitest) echo "$VITEST_RELATIVIZING_CMD";            return ;;
            jest)   echo 'npx jest ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';       return ;;
            mocha)  echo 'npx mocha ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';      return ;;
            *)      _dtc_js_npm_fallback;                                           return ;;
          esac ;;
      esac
    fi
    # Single package: a vitest runner needs the RELATIVIZING positional (same abs-
    # path bug as the monorepo); jest/mocha/other keep the `npm test --` positional
    # default (empty runs the suite).
    case "$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$TOPLEVEL/package.json" | head -1)" in
      *vitest*) echo "$VITEST_RELATIVIZING_CMD"; return ;;
    esac
    _dtc_js_npm_fallback; return
}

# The bare `npm test --` default — UNCHANGED, except that it is not emitted for a
# `test` script the inert filter can PROVE runs nothing (an empty script, npm's
# own generated `echo … && exit 1` placeholder, an `echo`-only stand-in). It is
# reached only AFTER the vitest/jest/mocha and workspace-runner branches have
# declined, so no repo that names a runner anywhere can land here.
#
# A refusal here RETURNS 1 so `_dtc_js` FALLS THROUGH to the generic arm, rather
# than claiming the repo with an empty answer. That is S147's recorded lesson in
# the dotnet comment above — a cure must never take an existing arm's answer
# away — and it means a repo with npm's placeholder plus a real Makefile `test:`
# target now gets `make test` instead of a command that runs nothing.
_dtc_js_npm_fallback() {
  _dtc_inert_npm_test >/dev/null && return 1
  echo 'npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'
}

# python (S2xx) — the arm claims a RUNNER, never a MARKER. `pyproject.toml` /
# `pytest.ini` / `tox.ini` says "this is a python repo"; it does NOT say that
# pytest is the runner. pytest is a THIRD-PARTY package, absent on any machine
# with a bare interpreter (`which pytest` → not found, measured on this build
# machine), so claiming it from the marker alone recorded a runner that cannot
# launch — and a real measured run then logged "the runner still cannot launch"
# in the same breath as declaring the test system ESTABLISHED.
#
# That is the dotnet arm's regression one arm over (see its comment above):
# CLAIMING ON THE MERE PRESENCE OF A MARKER. The cure is the dotnet arm's cure:
#   • pytest EVIDENCE (its own config file/table, a conftest.py, or pytest
#     DECLARED in a manifest) → `pytest`, unchanged, scope and all.
#   • NO pytest evidence but python TEST FILES by unittest's own discovery
#     convention → `python3 -m unittest discover`: the STANDARD-LIBRARY runner,
#     zero install, shipped with the very interpreter the marker implies — and
#     what the reviewer itself recommended on the measured stdlib repo.
#   • NEITHER → return 1 and FALL THROUGH, so the generic Makefile /
#     tests/run.sh arms still get their turn (a `pyproject.toml` beside a
#     Makefile `test:` target seeded `pytest` and took `make test` away — the
#     same regression the dotnet comment records). An empty answer is an honest
#     answer; inventing a runner to fill the slot is the defect, not the cure.
#
# Runner choice follows the repo's declarations, not PATH. Its interpreter
# initially follows an existing repo environment: LCARS testenv, .venv, then venv.
# unittest itself is stdlib, but the suite's imports may not be (OF2: PyYAML).
# Record the absolute interpreter so gate worktrees reuse those dependencies.
# Fresh init probes alternatives before retaining a failed detected candidate.
#
# LEDGERED (recorded, not fixed): the unittest leg looks for test files at the
# top level and in the DIRECT children of `tests/` / `test/` only. A suite nested
# deeper (`tests/unit/test_x.py`) therefore claims nothing rather than seeding a
# `discover` that would collect zero tests — unclaimed, not mis-claimed.
#
# KEEP IN STEP with `_DETECT_MARKER_FILES`/`_DETECT_MARKER_GLOBS` in
# web/lcars_serve/local_adapter.py — the board's memo must see every file this
# arm reads, or CLI and board drift apart (the S146 D2 contract).

# Any mention of pytest in a file the repo uses to DECLARE its tooling. Anchored
# on both sides so `pytest-cov` / `pytest_asyncio` still count (they are pytest
# plugins) while a word that merely ENDS in pytest cannot match.
_DTC_PY_PYTEST_RE='(^|[^A-Za-z0-9_])(pytest|py\.test)'

_dtc_py_pytest_evidence() {   # 0 when this repo declares pytest as its runner
  local f
  [ -f "$TOPLEVEL/pytest.ini" ]  && return 0   # pytest's own config file
  [ -f "$TOPLEVEL/conftest.py" ] && return 0   # pytest's own fixture file
  for f in pyproject.toml setup.cfg setup.py tox.ini Pipfile; do
    [ -f "$TOPLEVEL/$f" ] || continue
    grep -Eq "$_DTC_PY_PYTEST_RE" "$TOPLEVEL/$f" 2>/dev/null && return 0
  done
  for f in "$TOPLEVEL"/requirements*.txt; do   # nullglob-safe (bash-3.2)
    [ -e "$f" ] || continue
    grep -Eq "$_DTC_PY_PYTEST_RE" "$f" 2>/dev/null && return 0
  done
  return 1
}

# Prints "<start-dir>|<pattern-or-empty>" for a unittest-discoverable layout, or
# returns 1. The PATTERN matters: `discover`'s default is `test*.py`, so a repo
# whose files are all `*_test.py` needs `-p` or it collects nothing (measured).
_dtc_py_unittest_layout() {
  local d f
  for d in tests test .; do
    [ "$d" = "." ] || [ -d "$TOPLEVEL/$d" ] || continue
    for f in "$TOPLEVEL/$d"/test*.py; do
      [ -e "$f" ] && { printf '%s|' "$d"; return 0; }
    done
    for f in "$TOPLEVEL/$d"/*_test.py; do
      [ -e "$f" ] && { printf '%s|*_test.py' "$d"; return 0; }
    done
  done
  return 1
}

_dtc_python_environments() {
  local common candidate
  common="$(git -C "$TOPLEVEL" rev-parse --git-common-dir 2>/dev/null)" || common=""
  case "$common" in ''|/*) : ;; *) common="$TOPLEVEL/$common" ;; esac
  for candidate in "${common:+$common/lcars/testenv/bin/python}" \
      "$TOPLEVEL/.venv/bin/python" "$TOPLEVEL/venv/bin/python"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
  done
}

_dtc_python_interpreter() {
  local candidate
  candidate="$(_dtc_python_environments | head -1)"
  if [ -n "$candidate" ]; then
    "${LCARS_PYTHON_BIN:-python3}" -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$candidate"
    return $?
  fi
  printf 'python3'
}

_dtc_python() {
  # The MARKER GATE is unchanged — the same three files decide whether this arm
  # is asked at all. Only what it does once asked has changed.
  [ -f "$TOPLEVEL/pyproject.toml" ] || [ -f "$TOPLEVEL/pytest.ini" ] || [ -f "$TOPLEVEL/tox.ini" ] || return 1
  local python
  python="${1:-$(_dtc_python_interpreter)}"
  if _dtc_py_pytest_evidence; then
    if [ "$python" = python3 ]; then
      echo 'pytest "${LCARS_TESTS_DIR:-.}"'
    else
      echo "$python -m pytest \"\${LCARS_TESTS_DIR:-.}\""
    fi
    return 0
  fi
  local layout dir pat
  layout="$(_dtc_py_unittest_layout)" || return 1
  dir="${layout%%|*}"; pat="${layout#*|}"
  if [ -n "$pat" ]; then
    echo "$python -m unittest discover -s \"\${LCARS_TESTS_DIR:-$dir}\" -p \"$pat\""
  else
    echo "$python -m unittest discover -s \"\${LCARS_TESTS_DIR:-$dir}\""
  fi
}

_dtc_rust() { [ -f "$TOPLEVEL/Cargo.toml" ] || return 1; echo "cargo test"; }
_dtc_go()   { [ -f "$TOPLEVEL/go.mod" ]     || return 1; echo "go test ./..."; }

# dotnet/C# (S147): `dotnet test` is project-oriented, not directory-oriented —
# it wants the TEST PROJECT, so the seed names it explicitly (a bare `dotnet
# test` from the root either finds nothing or fans out across the solution).
# Exactly ONE test project seeds; SEVERAL is internally AMBIGUOUS — emit NO
# command (the caller warns, naming them all, per the S105 idiom) rather than
# pick one by sort order.
#
# The arm CLAIMS the repo only when a dotnet TEST PROJECT was actually found.
# Claiming on the mere presence of a marker was a regression: a repo with
# `App.csproj` plus a Makefile `test:` target seeded `make test` before S147 and
# suddenly seeded nothing — S147 is supposed to ADD dotnet's missing legs, never
# to take an existing arm's answer away. With no test project it returns 1 and
# the chain falls through to the pre-existing fallbacks exactly as it always did.
_dtc_dotnet() {
  detect_dotnet_markers || return 1
  local dn_projs dn_n
  dn_projs="$(detect_dotnet_test_projects | grep . || :)"
  # NB: `grep -c` exits 1 on a zero count, hence the `|| :` and the numeric guard.
  dn_n="$(printf '%s' "$dn_projs" | grep -c . || :)"
  case "$dn_n" in ''|*[!0-9]*) dn_n=0 ;; esac
  [ "$dn_n" -ge 1 ] || return 1
  [ "$dn_n" -eq 1 ] && { echo "dotnet test $dn_projs"; return 0; }
  echo ""   # several → claimed, but deliberately no command
}

# Ruby (S145): pick the runner from the layout. rspec when the Gemfile names it
# or a spec/ dir exists; minitest via `rake test` when a test/ dir + Rakefile are
# present. A Gemfile prefixes `bundle exec`. When BOTH an rspec (spec/) and a
# minitest (test/ + Rakefile) layout are present WITHOUT a decisive Gemfile rspec
# signal, the runner is internally AMBIGUOUS: emit NO command (the caller warns,
# naming both) rather than guess. A gem library with only a *.gemspec/Rakefile and
# no spec//test/ also emits nothing. Reached only for a single-stack ruby repo.
_dtc_ruby() {
  [ -f "$TOPLEVEL/Gemfile" ] || [ -f "$TOPLEVEL/Rakefile" ] || [ -f "$TOPLEVEL/config.ru" ] \
    || [ -d "$TOPLEVEL/spec" ] || ls "$TOPLEVEL"/*.gemspec >/dev/null 2>&1 || return 1
  local rb_prefix="" rb_rspec=0 rb_mini=0 rb_gem_rspec=0
  [ -f "$TOPLEVEL/Gemfile" ] && rb_prefix="bundle exec "
  { [ -f "$TOPLEVEL/Gemfile" ] && grep -q 'rspec' "$TOPLEVEL/Gemfile"; } && rb_gem_rspec=1
  { [ "$rb_gem_rspec" = 1 ] || [ -d "$TOPLEVEL/spec" ]; } && rb_rspec=1
  { [ -d "$TOPLEVEL/test" ] && [ -f "$TOPLEVEL/Rakefile" ]; } && rb_mini=1
  # A Gemfile explicitly naming rspec is decisive even if a test/ dir also exists.
  [ "$rb_gem_rspec" = 1 ] && rb_mini=0
  if [ "$rb_rspec" = 1 ] && [ "$rb_mini" = 1 ]; then echo ""; return 0; fi
  if [ "$rb_rspec" = 1 ]; then echo "${rb_prefix}rspec"; return 0; fi
  if [ "$rb_mini" = 1 ];  then echo "${rb_prefix}rake test"; return 0; fi
  echo ""
}

# The generic runners, checked LAST so a real ecosystem always wins. A bash test
# runner (LCARS dogfoods its own tests/run.sh) already resolves a positional dir
# / $LCARS_TESTS_DIR (BUG-009), so scope it to the quarantined tests when the var
# is set, else the whole `tests` dir for a human.
#
# S299: each of the two runners is skipped when the inert filter can PROVE that
# artifact runs nothing — a `test:` target with no recipe and no prerequisites,
# a tests/run.sh holding no command. A skip FALLS THROUGH to the next check (and
# then out of the arm), so a repo with a no-op Makefile target beside a real
# tests/run.sh still gets the runner that works. Everything else is untouched:
# one recipe line, one prerequisite, or one command in the script and the answer
# is byte-identical to what it has always been.
_dtc_generic() {
  if [ -f "$TOPLEVEL/Makefile" ] && grep -q '^test:' "$TOPLEVEL/Makefile" \
      && ! _dtc_inert_make_test >/dev/null; then
    echo "make test"; return 0; fi
  if [ -f "$TOPLEVEL/tests/run.sh" ] && ! _dtc_inert_run_sh >/dev/null; then
    echo 'bash tests/run.sh "${LCARS_TESTS_DIR:-tests}"'; return 0; fi
  return 1
}

# The arm ORDER — the pre-147 if-chain order, preserved exactly.
DETECT_TEST_CMD_ARMS="js python rust go dotnet ruby generic"

detect_test_cmd() {
  local arm out
  for arm in $DETECT_TEST_CMD_ARMS; do
    if out="$("_dtc_$arm")"; then printf '%s\n' "$out"; return 0; fi
  done
  echo ""
}

# detect_test_cmd_for_stack <stack> — ONE stack's seed rule, asked in isolation.
# Used to offer a real command per candidate on an AMBIGUOUS repo, so choosing
# never costs a discovery worker. Empty when that stack has no rule here or
# cannot pin a runner.
detect_test_cmd_for_stack() {
  case " $DETECT_TEST_CMD_ARMS " in
    *" $1 "*) "_dtc_$1" 2>/dev/null || printf '' ;;
    *)        printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# STACK DETECTION (S105 — multi-stack breadth)
# ---------------------------------------------------------------------------
# detect_stack — inspect the repo's TOP LEVEL for language/build markers and echo
# ONE stack id. The id is the classifier key the S104 `lcars run` arms are keyed
# by (rust/go/python/js/dotnet/jvm), so seeding it into config.json lets every
# downstream stage know the mission's ecosystem without re-sniffing.
#
# Marker → id:
#   Cargo.toml                                   → rust
#   go.mod                                       → go
#   pyproject.toml / setup.py                    → python
#   package.json                                 → js
#   *.csproj / *.sln                             → dotnet
#   pom.xml / build.gradle / build.gradle.kts    → jvm
#   Gemfile / *.gemspec / Rakefile / config.ru   → ruby
#
# Several DISTINCT stacks present   → ambiguous(<comma-list, in detection order>)
# NONE present                      → unknown
#
# Reads $TOPLEVEL (the repo root) from the caller's environment, exactly like
# detect_worktree_setup_cmd / init's detect_test_cmd. POSIX/bash-3.2 portable and
# nullglob-safe: glob markers (*.csproj, build.gradle*) are probed with a
# `for f in …; do [ -e "$f" ]` guard so an UNMATCHED glob (which stays a literal
# under bash-3.2) can never false-positive. Shared by BOTH `lcars init` and
# `lcars update` so the two can never disagree on a repo's stack.
detect_stack() {
  local candidates="" f matched

  [ -f "$TOPLEVEL/Cargo.toml" ] && candidates="$candidates rust"
  [ -f "$TOPLEVEL/go.mod" ]     && candidates="$candidates go"
  { [ -f "$TOPLEVEL/pyproject.toml" ] || [ -f "$TOPLEVEL/setup.py" ]; } \
    && candidates="$candidates python"
  [ -f "$TOPLEVEL/package.json" ] && candidates="$candidates js"

  # dotnet — any *.csproj, *.sln or *.slnx, at the top level or within the
  # bounded marker depth (detect_dotnet_markers). S147: `.slnx` is the XML
  # solution format .NET 10's `dotnet new sln` now emits by default, and the
  # canonical `dotnet new xunit -o MyApp.Tests` layout keeps its only project one
  # directory down with no root solution at all — both OBSERVED in-session with
  # SDK 10.0.107, and both read as `unknown` under a top-level-only glob. Purely
  # ADDITIVE: every path that matched before still matches.
  detect_dotnet_markers && candidates="$candidates dotnet"

  # jvm — Maven (pom.xml) or Gradle (build.gradle / build.gradle.kts).
  matched=0
  for f in "$TOPLEVEL"/pom.xml "$TOPLEVEL"/build.gradle "$TOPLEVEL"/build.gradle.kts; do
    [ -e "$f" ] && { matched=1; break; }
  done
  [ "$matched" -eq 1 ] && candidates="$candidates jvm"

  # ruby (S145) — Gemfile / *.gemspec / Rakefile / config.ru (nullglob-safe probe;
  # an unmatched *.gemspec glob stays literal under bash-3.2, so the -e guard keeps
  # it from false-positiving). A spec/ or test/ dir is runner evidence (seed side),
  # never a stack marker on its own.
  matched=0
  for f in "$TOPLEVEL"/Gemfile "$TOPLEVEL"/*.gemspec "$TOPLEVEL"/Rakefile "$TOPLEVEL"/config.ru; do
    [ -e "$f" ] && { matched=1; break; }
  done
  [ "$matched" -eq 1 ] && candidates="$candidates ruby"

  # Strip the leading space and split on whitespace to count distinct stacks.
  # shellcheck disable=SC2086
  set -- $candidates
  case $# in
    0) echo "unknown" ;;
    1) echo "$1" ;;
    *) echo "ambiguous($(echo "$candidates" | sed 's/^ *//; s/ /,/g'))" ;;
  esac
}

# ---------------------------------------------------------------------------
# TEST PROBE — the ONE live run (shared by `lcars update` and `lcars init`)
# ---------------------------------------------------------------------------
# lcars_test_readiness (below) is CHEAP: it never runs anything, so "ready"
# means the COMMAND resolves, not that the SUITE works. This is the other half
# — an actual bounded run — for the one-off callers that can afford it.

# run_probe <cmd> — run the test command ONCE from the repo root, BOUNDED by
# $LCARS_PROBE_TIMEOUT (default 500s; perl's alarm survives exec, so the timer
# rides into the spawned bash). Sets PROBE_OUTCOME (pass|fail|zero-collected|
# timeout), PROBE_RC, and PROBE_OUT (captured-output file). Zero-collected is
# its OWN honest outcome, never a pass — the signature REUSES the rg_signature
# `zerotests` + proof_zero_collected phrasings from skills/lcars-run/run.sh
# (keep the two in step).
PROBE_TIMEOUT="${LCARS_PROBE_TIMEOUT:-${LCARS_GATE_TIMEOUT_DEFAULT:-500}}"
# S308: PROBE_SECS — the suite's measured WALL-CLOCK. This probe is the only
# place LCARS ever times a repo's whole suite, and it used to throw the number
# away: on the repo this was measured against it timed out and said only "fix
# it before relying on the
# Implement gates", while those gates went on to kill every proof leg at the
# 120s default, five times, with nowhere for the repo to record what it needs.
# Measured, not estimated; recorded, not inferred.
PROBE_SECS=0
lcars_probe_zero_executed() { # output-file → 0 when unittest has no genuine passes
  # unittest's "Ran" includes skips and expected failures; neither certifies.
  # Sum completed summaries so a mixed run with a genuine pass still qualifies.
  awk '
    /^Ran [0-9]+ tests? in / { count = $2; pending = 1 }
    pending && /^(OK|FAILED|NO TESTS RAN)([[:space:]]|$)/ {
      skipped = 0
      if (match($0, /skipped=[0-9]+/))
        skipped = substr($0, RSTART + 8, RLENGTH - 8) + 0
      expected = 0
      if (match($0, /expected failures=[0-9]+/))
        expected = substr($0, RSTART + 18, RLENGTH - 18) + 0
      executed += count - skipped - expected
      seen = 1; pending = 0
    }
    END { exit !(seen && executed == 0) }
  ' "$1"
}

run_probe() {
  local cmd="$1" _t0 _t1
  PROBE_OUT="$(mktemp "${TMPDIR:-/tmp}/lcars-probe.XXXXXX")"
  _t0="$(date +%s 2>/dev/null || echo 0)"
  ( cd "$TOPLEVEL" && perl -e 'alarm shift; exec @ARGV or exit 127' \
      "$PROBE_TIMEOUT" bash -c "$cmd" ) >"$PROBE_OUT" 2>&1
  PROBE_RC=$?
  _t1="$(date +%s 2>/dev/null || echo 0)"
  PROBE_SECS=$((_t1 - _t0)); [ "$PROBE_SECS" -ge 0 ] || PROBE_SECS=0
  # S147: THREE VSTest phrasings, all exiting 0 (observed, SDK 10.0.107) — a
  # filter that matches nothing, a test project with no test methods, and a run
  # whose every discovered case was SKIPPED (`[Fact(Skip=…)]`), which prints
  # neither "no test" phrase and used to read here as "the suite ran and passed".
  # They are the dotnet green-on-nothing trap, so the probe names them too; the
  # skipped form keys on the NUMBERS (zero failed AND zero passed) so a real
  # 1-passed/1-skipped run stays a pass. Keep in step with rg_signature
  # `zerotests` + proof_zero_collected in skills/lcars-run/run.sh.
  #
  # S168 NODE'S BUILT-IN RUNNER — measured live on a greenfield repo whose
  # package.json is {"scripts":{"test":"node --test"}} with no test files. It
  # prints NONE of the phrasings above; it prints its own counter block and
  # EXITS 0 (`ℹ tests 0` / `ℹ suites 0` / `ℹ pass 0` / `ℹ fail 0` …), so init
  # certified "TEST SYSTEMS ONLINE" on a repo with zero tests. The arm below
  # keys on the `tests` COUNTER alone, and is anchored at BOTH ends so it can
  # never fire on a healthy run:
  #  • `^[^0-9A-Za-z]*` — everything before `tests` must be non-alphanumeric,
  #    so it matches node's multi-byte `ℹ ` prefix (and TAP's `# `) while
  #    `subtests 0` cannot match. The other counters are different WORDS, so a
  #    green run's `fail 0` / `suites 0` / `skipped 0` / `todo 0` are untouched.
  #  • `0[[:space:]]*$` — the count must be a STANDALONE zero (the S106
  #    substring hazard): `tests 10`, `tests 01` and `tests 4` all miss.
  local zero='No test files found|No test suite found in|No tests found|no tests ran|Ran 0 tests|collected 0 items|(^|[^0-9])0 examples, 0 failures$|(^|[^0-9])0 runs, 0 assertions|no tests to run|test result: ok\. 0 passed|^No test matches the given testcase filter .*\.dll|^No test is available in .*\.dll|^(Passed|Failed|Skipped)! +- +Failed: +0, +Passed: +0,|^[^0-9A-Za-z]*tests 0[[:space:]]*$'
  # S147: MSBuild never even REACHED a test run — the project/solution the
  # command names is not there. Reporting that as "the suite ran but reported
  # failures" sends the captain hunting a test failure that does not exist.
  local cantrun='^MSBUILD : error MSB100[39]:'
  if [ "$PROBE_RC" -eq 142 ]; then          # 128 + SIGALRM(14): the alarm fired
    PROBE_OUTCOME="timeout"
  elif grep -Eq "$cantrun" "$PROBE_OUT"; then
    PROBE_OUTCOME="cannot-run"
  elif grep -Eq "$zero" "$PROBE_OUT" || lcars_probe_zero_executed "$PROBE_OUT"; then
    PROBE_OUTCOME="zero-collected"
  elif [ "$PROBE_RC" -eq 0 ]; then
    PROBE_OUTCOME="pass"
  else
    PROBE_OUTCOME="fail"
  fi
}

# Called only for a freshly seeded Python command after its first live probe.
# A failed alternative never replaces the original command or its timing evidence.
lcars_probe_python_alternatives() {
  LCARS_PROBED_TEST_CMD="$1"
  [ "$PROBE_OUTCOME" != pass ] || return 0
  [ -n "$(_dtc_python_environments)" ] || return 0
  local original_out="$PROBE_OUT" original_rc="$PROBE_RC"
  local original_outcome="$PROBE_OUTCOME" original_secs="$PROBE_SECS"
  local candidate quoted cmd seen=""
  report_probe
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$seen" in *"|$candidate|"*) continue ;; esac
    seen="$seen|$candidate|"
    quoted="$("${LCARS_PYTHON_BIN:-python3}" -c \
      'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$candidate")" || return 1
    cmd="$(_dtc_python "$quoted")" || return 1
    [ "$cmd" != "$1" ] || continue
    echo "  … probing alternative Python environment ($cmd)"
    run_probe "$cmd"
    if [ "$PROBE_OUTCOME" = pass ]; then
      LCARS_PROBED_TEST_CMD="$cmd"
      rm -f "$original_out"
      return 0
    fi
    report_probe
    rm -f "$PROBE_OUT"
  done <<PY_ENVS
$(_dtc_python_environments)
$(command -v python3)
PY_ENVS
  PROBE_OUT="$original_out"; PROBE_RC="$original_rc"
  PROBE_OUTCOME="$original_outcome"; PROBE_SECS="$original_secs"
}

# report_probe — the ship-status readout for the last run_probe.
report_probe() {
  case "$PROBE_OUTCOME" in
    pass)
      echo "  ✓ PROBE COMPLETE — test systems responding: the suite ran and passed in ${PROBE_SECS}s." ;;
    fail)
      echo "  ✗ PROBE FAILED — the suite ran but reported failures (exit $PROBE_RC)."
      tail -n 5 "$PROBE_OUT" 2>/dev/null | sed 's/^/      /' ;;
    zero-collected)
      echo "  ⚠ PROBE INCONCLUSIVE — the runner recorded ZERO genuinely passing tests (none collected, all skipped, or only expected failures)."
      echo "    That is not a pass: the command may be scoped to the wrong place." ;;
    cannot-run)
      echo "  ⚠ PROBE COULD NOT RUN — the command never reached a test run: the"
      echo "    project or solution it names could not be loaded (exit $PROBE_RC)."
      tail -n 5 "$PROBE_OUT" 2>/dev/null | sed 's/^/      /' ;;
    timeout)
      echo "  ⚠ PROBE TIMED OUT — no verdict within ${PROBE_TIMEOUT}s; the suite never settled." ;;
  esac
}

# ---------------------------------------------------------------------------
# S308: SEED THE GATE TIMEOUT THE PROBE JUST MEASURED
# ---------------------------------------------------------------------------
# Passes supply measured wall-clock; timeouts supply only the exceeded bound.
# Both get twice that evidence, rounded up to 30s (at most the gate's 1h cap).
# A timeout never certifies the suite or promises the new budget is sufficient.
# Existing captain settings always win. The probe and gate ship at 500s.
lcars_gate_timeout_default() { # → the default gate timeout in seconds
  local d="${LCARS_GATE_TIMEOUT_DEFAULT:-500}"
  case "$d" in ''|*[!0-9]*) d=500 ;; esac
  [ "$d" -gt 0 ] 2>/dev/null || d=500
  printf '%s' "$d"
}
# Echoes the recommendation line(s) it printed; writes the key when it applies.
lcars_seed_gate_timeout() { # config-file seconds [pass|timeout]
  local config="$1" secs="${2:-0}" outcome="${3:-pass}" dflt want existing evidence
  case "$outcome" in pass|timeout) : ;; *) return 0 ;; esac
  [ "$outcome" != timeout ] || secs="$PROBE_TIMEOUT"
  case "$secs" in ''|*[!0-9]*) return 0 ;; esac
  dflt="$(lcars_gate_timeout_default)"
  if [ "$outcome" = pass ]; then
    [ "$secs" -gt "$dflt" ] || return 0
    evidence="this suite takes ${secs}s"
  else
    evidence="this suite exceeded ${secs}s; its full duration is unknown"
  fi
  [ -f "$config" ] || return 0
  existing="$(lcars_config_get_raw "$config" gateTimeout)"
  case "$existing" in
    ''|null)
      want=$(( secs * 2 ))
      want=$(( ((want + 29) / 30) * 30 ))
      [ "$want" -gt "$dflt" ] || want=$(( dflt + 30 ))
      [ "$want" -le 3600 ] || want=3600
      lcars_config_set_or_add_raw "$config" gateTimeout "$want" || return 1
      echo "  · $evidence —"
      echo "    recorded gateTimeout=$want in .git/lcars/config.json as a provisional proof budget."
      echo "    Adjust with: lcars update --gate-timeout <seconds> (1–3600)."
      echo "    LCARS_GATE_TIMEOUT in the environment still wins; a timeout is not a passing probe."
      ;;
    *)
      echo "  · $evidence; your recorded gateTimeout=$existing"
      echo "    (.git/lcars/config.json) is left exactly as it is."
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# TEST READINESS — the ONE verdict (S146)
# ---------------------------------------------------------------------------
# lcars_test_readiness — compute the repo's test-readiness verdict, CHEAP by
# construction: no test run, no network, no worker. The four states:
#
#   ready    testCommand set AND its first token resolves via `command -v`
#   missing  testCommand null/absent, detection has a candidate (suggestion)
#   broken   testCommand set but its first token does NOT resolve
#   unknown  testCommand null/absent AND no candidate, with NO stack detected —
#            the greenfield state: EXPECTED, not an alarm.
#   ambiguous  (S147) testCommand null/absent because SEVERAL test systems are
#            present and LCARS refuses to guess. NOT greenfield: this repo HAS
#            test systems, LCARS just cannot pick one — it needs the captain to
#            choose. Given its own voice so the bootstrap ("the crew will
#            establish them") and repair voices never blur on a repo that
#            already has real test infrastructure. TWO shapes reach it:
#              • several STACKS (rust + js …), and
#              • one stack that cannot pin its runner because it has several
#                candidates — today a dotnet repo with two test projects, which
#                warned and NAMED both projects and then declared the repo
#                greenfield on the very next line.
#
# Shared by `lcars init`/`lcars update`/`lcars status` (they source this file)
# and by the viewscreen daemon (via skills/lcars-init/readiness.sh), so CLI and
# board can never disagree. It NEVER writes anything — the sanctioned writers
# are `lcars update --test-command|--fix-tests` alone.
#
# Args: $1 = path to config.json. Reads $TOPLEVEL (repo root) for detection and
# for resolving a relative runner path. Sets, for the caller:
#   LCARS_TESTREADY_STATUS      ready|missing|broken|unknown|ambiguous
#   LCARS_TESTREADY_TESTCMD     the stored testCommand ("" when null/absent)
#   LCARS_TESTREADY_SUGGESTION  the detected candidate ("" unless status=missing)
#   LCARS_TESTREADY_STACKS      the ambiguity's candidate LABELS, comma-separated
#                               — stack ids for a multi-stack repo, test-project
#                               paths for one stack that cannot pin its runner
#                               ("" unless status=ambiguous)
#   LCARS_TESTREADY_CANDIDATES  one candidate COMMAND per line, so the captain
#                               can PICK instead of hiring a discovery worker
#                               ("" unless status=ambiguous)
#   LCARS_TESTREADY_INERT_WHY   (S299) the inert-declaration reason, when the
#                               repo root HOLDS test configuration that provably
#                               runs nothing — a recipe-less `test:` target, an
#                               empty tests/run.sh, an npm placeholder script.
#                               Set only for status=unknown, because that is the
#                               one verdict that means "detection found no
#                               command" and so the one that can be explained by
#                               naming the file that is nevertheless sitting
#                               there. "" everywhere else.
lcars_test_readiness_status() {
  local config="$1"
  LCARS_TESTREADY_STATUS=""
  LCARS_TESTREADY_TESTCMD=""
  LCARS_TESTREADY_SUGGESTION=""
  LCARS_TESTREADY_STACKS=""
  LCARS_TESTREADY_CANDIDATES=""
  LCARS_TESTREADY_BROKEN_WHY=""
  LCARS_TESTREADY_INERT_WHY=""

  local tc=""
  [ -f "$config" ] && tc="$(lcars_config_get "$config" testCommand)"

  if [ -n "$tc" ]; then
    LCARS_TESTREADY_TESTCMD="$tc"
    # S185 fix round 1 — A COMMAND NO SHELL CAN PARSE IS NOT "ready".
    # The only check below is that the FIRST TOKEN resolves, so a testCommand
    # that had been truncated mid-quote —
    #   npx vitest run ${LCARS_TESTS_DIR:+\
    # — still reported `ready` (and `foundation: ready`, which is what unlocks
    # `lcars file` and the holodeck) purely because `npx` is on PATH. Every gate
    # runs the command through `bash -c`, so `bash -n` asks exactly the question
    # the gate will ask, and it stays CHEAP: it PARSES, it never executes.
    #
    # This is NOT a check that the runner is genuine — that question is retired
    # by design (the captain at Verify is the proof). It only refuses to call a
    # string a command when no shell can read it as one.
    if ! bash -n -c "$tc" >/dev/null 2>&1; then
      LCARS_TESTREADY_STATUS="broken"
      LCARS_TESTREADY_BROKEN_WHY="unparseable"
      return 0
    fi
    # First token of the command (no glob expansion — `read` splits safely).
    local first rest
    read -r first rest <<EOF2
$tc
EOF2
    case "$tc" in
      \'*|\"*)
        first="$("${LCARS_PYTHON_BIN:-python3}" -c \
          'import shlex,sys; print(next(iter(shlex.shlex(sys.argv[1], posix=True))))' "$tc")" \
          || { LCARS_TESTREADY_STATUS="broken"; return 0; }
        ;;
    esac
    # Resolve from the repo root so a relative runner (node_modules/.bin/…)
    # resolves the way the gate would run it.
    if ( cd "${TOPLEVEL:-.}" 2>/dev/null && command -v "$first" >/dev/null 2>&1 ); then
      LCARS_TESTREADY_STATUS="ready"
    else
      LCARS_TESTREADY_STATUS="broken"
    fi
    return 0
  fi

  # No command stored: does detection have a candidate? Mirror init's seeding
  # rule EXACTLY (S105): only an AMBIGUOUS multi-stack repo refuses to guess;
  # an unknown stack still consults detect_test_cmd (Makefile / tests/run.sh
  # repos have a perfectly detectable runner without a stack id).
  local stack cand="" s
  stack="$(detect_stack)"
  case "$stack" in
    # S147: an AMBIGUOUS repo is its OWN state, not greenfield. It has test
    # systems — several — and LCARS refuses to guess between them; calling that
    # "no test systems found" (and promising the first mission's crew would
    # establish them) was a lie on a repo that already has real infrastructure.
    ambiguous*)
      LCARS_TESTREADY_STATUS="ambiguous"
      LCARS_TESTREADY_STACKS="${stack#ambiguous(}"
      LCARS_TESTREADY_STACKS="${LCARS_TESTREADY_STACKS%)}"
      # A real command per candidate stack, so `--fix-tests` can offer a PICK
      # instead of hiring a paid discovery crew to choose (which is exactly what
      # the "LCARS will not choose for you" line promised it would not do).
      for s in $(printf '%s' "$LCARS_TESTREADY_STACKS" | tr ',' ' '); do
        cand="$(detect_test_cmd_for_stack "$s")"
        [ -n "$cand" ] && LCARS_TESTREADY_CANDIDATES="${LCARS_TESTREADY_CANDIDATES}${cand}
"
      done
      return 0 ;;
    *)          cand="$(detect_test_cmd)" ;;
  esac
  if [ -n "$cand" ]; then
    LCARS_TESTREADY_STATUS="missing"
    LCARS_TESTREADY_SUGGESTION="$cand"
    return 0
  fi
  # No command AND no candidate. Before calling this greenfield, ask whether the
  # single detected stack is ambiguous WITHIN ITSELF — a dotnet repo with two
  # test projects has real test infrastructure and simply needs the captain to
  # choose. Folding that into `unknown` made init warn "SEVERAL test projects are
  # present", name both, and then declare the repo greenfield on the next line.
  local alt; alt="$(lcars_stack_alternatives "$stack")"
  if [ -n "$alt" ]; then
    LCARS_TESTREADY_STATUS="ambiguous"
    LCARS_TESTREADY_CANDIDATES="$alt"
    LCARS_TESTREADY_STACKS="$(printf '%s' "$alt" | sed 's/^dotnet test //' | tr '\n' ',' | sed 's/,$//')"
    return 0
  fi
  LCARS_TESTREADY_STATUS="unknown"
  # S299 fix round 1 — `unknown` means DETECTION FOUND NO COMMAND, and until now
  # that is all any surface could say. But a repo can reach `unknown` while
  # holding a file the captain (or a worker) deliberately put there to be the
  # test system — a `test:` target with no recipe, a tests/run.sh that only
  # echoes, npm's generated placeholder. Naming it is what makes the refusal
  # actionable, and it is the ONLY thing this reason does: it is a string for the
  # readiness line, never an input to a verdict, so it cannot move a gate.
  LCARS_TESTREADY_INERT_WHY="$(detect_inert_test_config 2>/dev/null | head -1)"
  return 0
}

# ---------------------------------------------------------------------------
# THE FOUNDATION AXIS (S183) — "does this repo HAVE a test system at all?"
# ---------------------------------------------------------------------------
# `lcars_test_readiness_status` (above) answers ONE question: *is a test command
# configured, or detectable?* It has always answered `unknown` when the answer is
# no — REGARDLESS of how much code or how many frameworks the repo holds. So a
# `git init` on an empty directory and an npm-workspaces monorepo whose three
# packages all run vitest produce the SAME verdict, and the readiness line told
# both of them "◇ NO TEST SYSTEMS FOUND — a greenfield repo".
#
# That is a lie on the monorepo, and S183's gate cannot be built on it. This is
# the ADDITIVE SECOND AXIS — a separate variable, decided on POSITIVE EVIDENCE
# (test files, framework manifests / dev-dependencies, per-package runners in a
# workspace, a declared runner the repo's own tooling names), NEVER on the
# absence of a configured command:
#
#   LCARS_TESTREADY_FOUNDATION
#     greenfield    nothing is there — no code, no tests, no test system
#     untested      code exists, and there is no test system to prove it
#     unconfigured  a test system EXISTS; LCARS just has no command for it
#                   (the `lcars update --test-command` / `--fix-tests` case)
#     ready         a test command is configured and its runner resolves
#   LCARS_TESTREADY_FOUNDATION_WHY   the evidence, in one phrase, for the readout
#
# `LCARS_TESTREADY_STATUS` and its five values are UNTOUCHED — init, update,
# status, the viewscreen and run.sh's readiness_verdict all keep branching on
# exactly what they branched on before. Consumers that need to know whether the
# repo has a FOUNDATION (the S183 filing gate, S184's Establish Vision) read the
# new variable instead of re-deriving it.
#
# WHICH WAY THIS ERRS. `unconfigured` is the permissive answer and `untested` /
# `greenfield` are the ones that refuse a filing, so every rule below is written
# to reach `unconfigured` on ANY genuine sign of a test system. Refusing a repo
# that has one is a worse failure than letting a repo through that does not:
# the second is caught by S182's wall at Implement, the first strands a captain.
#
# ⚠ WHAT THIS IS NOT. It is NOT a mechanical check that a runner is genuine —
# that question was attacked three ways and beaten (see greenfield-dev.md, *What
# we are NOT changing*, 2026-09-05). It classifies a repo the CAPTAIN then acts
# on; it never certifies a runner a worker declared.

# _lcars_fnd_find <root> <maxdepth> <predicate…> — a bounded, pruned `find` over
# the working tree. The prune list is the usual build/vendor noise plus `.git`,
# so a repo's own dependencies (whose node_modules is FULL of other people's test
# files) can never be mistaken for this repo's test system.
_lcars_fnd_find() {
  local root="$1" depth="$2"; shift 2
  find "$root" -maxdepth "$depth" \
    \( -name .git -o -name node_modules -o -name vendor -o -name target \
       -o -name dist -o -name build -o -name .venv -o -name venv \
       -o -name .next -o -name .tox -o -name .cache -o -name coverage \
       -o -name Pods -o -name .gradle \) -prune \
    -o "$@" 2>/dev/null
}

# lcars_foundation_workspace_marker <root> — the monorepo marker this repo
# carries, or "". LIFTED VERBATIM (bar its name) from the shelved S183 salvage
# branch `wip/s183-canary-salvage` @ 04fee49, where it was verified: these are
# the markers `_dtc_js` / `detect_stack` / `detect_workspace_runner` already key
# off, plus their siblings in the other ecosystems. A pnpm workspace is marked by
# `pnpm-workspace.yaml` and a root `package.json` is conventional, NOT required —
# which is exactly the shape that read as greenfield.
lcars_foundation_workspace_marker() { # root → the marker name, or ""
  local r="${1:-${TOPLEVEL:-.}}"
  [ -f "$r/pnpm-workspace.yaml" ] && { printf 'pnpm-workspace.yaml'; return 0; }
  [ -f "$r/lerna.json" ]          && { printf 'lerna.json'; return 0; }
  [ -f "$r/nx.json" ]             && { printf 'nx.json'; return 0; }
  [ -f "$r/turbo.json" ]          && { printf 'turbo.json'; return 0; }
  [ -f "$r/rush.json" ]           && { printf 'rush.json'; return 0; }
  [ -f "$r/go.work" ]             && { printf 'go.work'; return 0; }
  if [ -f "$r/package.json" ] && grep -q '"workspaces"[[:space:]]*:' "$r/package.json" 2>/dev/null; then
    printf 'a "workspaces" key in package.json'; return 0
  fi
  if [ -f "$r/Cargo.toml" ] && grep -q '^\[workspace\]' "$r/Cargo.toml" 2>/dev/null; then
    printf '[workspace] in Cargo.toml'; return 0
  fi
  printf ''
}

# The RUNNER vocabulary — the names of actual test runners, as they appear in a
# command line. Used to tell a real `test` script from the two impostors that
# defeated earlier attempts at this: npm's default `echo "Error: no test
# specified" && exit 1`, and a script literally named `test` that tests nothing.
# Neither NAMES a runner, so neither matches.
LCARS_TEST_RUNNER_TOKENS='vitest|jest|mocha|jasmine|karma|qunit|cypress|playwright|ava|tape|uvu|node --test|node:test|deno test|bun test|nyc|c8|pytest|py\.test|unittest|nose2|tox|cargo test|go test|gotestsum|rspec|minitest|rake test|dotnet test|xunit|nunit|mstest|make test|bats|shunit2|phpunit|pest|gradle test|mvn test|mvn verify|swift test|ctest|mix test|scalatest|junit|testng|rustest|behave|robot|cucumber'

# The DEPENDENCY vocabulary — package.json keys that only appear when a JS test
# system is actually installed (or declared). A dev-dependency is positive
# evidence even when the runner is not installed on this machine: the repo HAS a
# test system, LCARS simply has no command for it.
LCARS_TEST_DEP_KEYS='vitest|jest|mocha|jasmine|jasmine-core|karma|qunit|cypress|playwright|@playwright/[a-z-]+|ava|tape|uvu|tap|node-tap|c8|nyc|chai|sinon|supertest|@testing-library/[a-z-]+|@jest/globals|ts-jest|babel-jest|jest-environment-[a-z-]+|@vitest/[a-z-]+|enzyme|testcafe|nightwatch|@types/jest|@types/mocha|@swc/jest|jsdom'

# _lcars_ev_balanced — 0 when the quoting in <string> is evenly paired and the
# string does not end mid-expansion. The FOUNDATION evidence phrase is
# captain-facing PROSE (the CLI prints it; the board renders it in its
# `found: …` chip), so anything that ends a quote it never opened reads as a
# corrupted sentence rather than as a report.
_lcars_ev_balanced() {
  local s="$1" c n pair a b
  for c in '"' "'" '`'; do
    n="$(printf '%s' "$s" | tr -dc "$c" | wc -c | tr -d ' ')"
    [ $(( n % 2 )) -eq 0 ] || return 1
  done
  for pair in '{}' '()' '[]'; do
    a="$(printf '%s' "$s" | tr -dc "$(printf '%s' "$pair" | cut -c1)" | wc -c | tr -d ' ')"
    b="$(printf '%s' "$s" | tr -dc "$(printf '%s' "$pair" | cut -c2)" | wc -c | tr -d ' ')"
    [ "$a" = "$b" ] || return 1
  done
  case "$s" in *'$') return 1 ;; esac
  case "$s" in *'\') return 1 ;; esac
  return 0
}

# _lcars_ev_short_cmd — a detected command, shortened for that prose. WHOLE
# WORDS only, then backed off further until the quoting balances, with an
# ellipsis marking the cut. The predecessor was `cut -c1-60`, which severs a
# command at whatever character sits at column 60 — on the very command LCARS
# itself seeds it landed inside a nested parameter expansion and printed
#   this repo already runs `npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"`
# to a captain who only ever needed to know it found vitest.
_lcars_ev_short_cmd() {
  local s="$1" max="${2:-60}" out="" cand w
  [ "${#s}" -le "$max" ] && { printf '%s' "$s"; return 0; }
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    if [ -z "$out" ]; then cand="$w"; else cand="$out $w"; fi
    [ "${#cand}" -le "$max" ] || break
    out="$cand"
  done <<EV_WORDS
$(printf '%s' "$s" | tr '\t' ' ' | tr ' ' '\n')
EV_WORDS
  while [ -n "$out" ] && ! _lcars_ev_balanced "$out"; do
    case "$out" in
      *' '*) out="${out% *}" ;;
      *)     out="" ;;
    esac
  done
  # Nothing survived (a single enormous or unbalanced first token): fall back to
  # the leading token with every character that could dangle removed, so the
  # sentence is still readable even in the shape we have never seen.
  if [ -z "$out" ]; then
    out="$(printf '%s' "$s" | cut -c1-"$max" | tr -d '"'"'"'`${}()[]\\')"
    out="${out%% *}"
  fi
  printf '%s …' "$out"
}

# lcars_test_system_evidence — POSITIVE evidence that this repo has a test
# system. Echoes the evidence in one phrase and returns 0; returns 1 (silent)
# when there is none. Reads $TOPLEVEL like every other detector here.
lcars_test_system_evidence() {
  local root="${TOPLEVEL:-.}" f hit cand marker

  # 1. A declared runner the repo's OWN tooling names — the markers
  #    `detect_test_cmd`'s generic arm and the framework configs key off.
  if [ -f "$root/Makefile" ] && grep -q '^test:' "$root/Makefile" 2>/dev/null; then
    printf 'a Makefile `test:` target'; return 0
  fi
  [ -f "$root/tests/run.sh" ] && { printf 'tests/run.sh'; return 0; }
  for f in pytest.ini tox.ini conftest.py .rspec phpunit.xml phpunit.xml.dist \
           karma.conf.js jest.config.js jest.config.ts jest.config.mjs \
           jest.config.cjs jest.config.json vitest.config.js vitest.config.ts \
           vitest.config.mjs vitest.workspace.ts playwright.config.ts \
           playwright.config.js cypress.config.js cypress.config.ts \
           .mocharc.json .mocharc.yml .mocharc.js codecept.conf.js; do
    [ -f "$root/$f" ] && { printf '%s' "$f"; return 0; }
  done

  # 2. The command LCARS itself would seed, when it NAMES a runner. This is the
  #    impostor filter: `_dtc_js` claims any package.json carrying a "test" key
  #    and falls back to a bare `npm test --`, so npm's default "no test
  #    specified" script and an `echo`-only script both produce a candidate that
  #    names no runner at all — and neither is evidence of anything.
  cand="$(detect_test_cmd 2>/dev/null)"
  if [ -n "$cand" ] && printf '%s' "$cand" | grep -qE "$LCARS_TEST_RUNNER_TOKENS"; then
    printf 'this repo already runs `%s`' "$(_lcars_ev_short_cmd "$cand" 60)"
    return 0
  fi

  # 3. Any package.json in the tree — root OR a workspace package — that
  #    installs a test framework, or whose `test` script names a runner. ONE
  #    tested package in a workspace is enough: the repo HAS a test system.
  hit="$(_lcars_fnd_find "$root" 4 -name package.json -type f -print | head -40)"
  if [ -n "$hit" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if grep -qE "\"($LCARS_TEST_DEP_KEYS)\"[[:space:]]*:" "$f" 2>/dev/null; then
        printf 'a test framework in %s' "${f#$root/}"; return 0
      fi
      if grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
          | grep -qE "$LCARS_TEST_RUNNER_TOKENS"; then
        printf 'a test script in %s' "${f#$root/}"; return 0
      fi
    done <<EV_PKG
$hit
EV_PKG
  fi

  # 3b. THE OTHER ECOSYSTEMS' MANIFESTS (S186). Step 3 reads package.json because
  #     that is where a JS test system is declared; every other ecosystem declares
  #     its own in its own build file, and NONE of them was being read. That is
  #     not a cosmetic mislabel — the foundation gate HARD-REFUSES `untested`, so
  #     a Gradle project with JUnit wired into its build, or a gem whose gemspec
  #     declares a development dependency on a test framework, was being told to
  #     Establish Vision on a project that already has a test system. This is the
  #     worse of the two failures the header names, and these are the arms it hit.
  #
  #     POSITIVE EVIDENCE ONLY, as everywhere else here: each rule below names a
  #     construct that appears when a test system is DECLARED, never the absence
  #     of one. A build file with no test wiring produces no evidence and falls
  #     through to the file-name and directory rules below, exactly as before.
  #
  #     NOT LISTED, deliberately: Cargo.toml `[dev-dependencies]` and go.mod. Both
  #     were checked and both are already answered EARLIER, at step 2 — `_dtc_rust`
  #     and `_dtc_go` yield `cargo test` / `go test ./...` from the manifest alone,
  #     which names a runner and settles it. That is the same fact the rust/go
  #     recipe rests on: the runner ships with the toolchain, so a crate or module
  #     always has one. A rule here would be unreachable code.
  #
  #     .csproj test package references are likewise already covered, at step 4,
  #     by `dotnet_csproj_is_test` (a Microsoft.NET.Test.Sdk reference, or the
  #     *Tests*.csproj naming convention).
  #
  #     Gemfile / gemspec — a test GROUP, or a declared development dependency on
  #     a test framework. `gem 'rspec'` at the top level of a Gemfile counts too:
  #     a repo does not depend on a test framework by accident.
  for f in Gemfile Gemfile.lock gems.rb; do
    [ -f "$root/$f" ] || continue
    if grep -Eq "group[[:space:]]*:?[[:space:]]*[:\"']?test" "$root/$f" 2>/dev/null \
       || grep -Eq "gem[[:space:]]+[\"'](rspec|rspec-core|rspec-rails|minitest|test-unit|shoulda|cucumber)" "$root/$f" 2>/dev/null; then
      printf 'a test group in %s' "$f"; return 0
    fi
  done
  for f in "$root"/*.gemspec; do
    [ -f "$f" ] || continue
    if grep -Eq "add_(development_)?dependency[[:space:]]*[(]?[[:space:]]*[\"'](rspec|minitest|test-unit|cucumber|shoulda)" "$f" 2>/dev/null; then
      printf 'a test framework in %s' "${f#$root/}"; return 0
    fi
  done

  #     Gradle — a `testImplementation` / `testCompile` dependency, a JUnit
  #     platform declaration, or a `test { … }` task block. Kotlin and Groovy DSL
  #     spell all three the same way.
  for f in build.gradle build.gradle.kts; do
    [ -f "$root/$f" ] || continue
    if grep -Eq '(testImplementation|testCompile|testRuntimeOnly|useJUnitPlatform|^[[:space:]]*(tasks\.named\(.test.\)|test[[:space:]]*\{))' "$root/$f" 2>/dev/null; then
      printf 'test dependencies in %s' "$f"; return 0
    fi
  done

  #     Maven — a test-scoped dependency, or the surefire/failsafe plugin that
  #     runs one. `<scope>test</scope>` is the construct: it exists for no other
  #     purpose than to put a dependency on the test classpath.
  if [ -f "$root/pom.xml" ]; then
    if grep -Eq '<scope>[[:space:]]*test[[:space:]]*</scope>|maven-(surefire|failsafe)-plugin' "$root/pom.xml" 2>/dev/null; then
      printf 'a test-scoped dependency in pom.xml'; return 0
    fi
  fi

  #     Python — the runner's own config table, a `test` extra, or setup.py's
  #     tests_require. (pytest.ini / tox.ini / conftest.py are already step 1.)
  if [ -f "$root/pyproject.toml" ]; then
    if grep -Eq '^\[tool\.(pytest|tox|nox|hatch\.envs\.(test|default)\.scripts)' "$root/pyproject.toml" 2>/dev/null \
       || grep -Eq '^[[:space:]]*(test|tests|testing|dev)[[:space:]]*=[[:space:]]*\[[^]]*(pytest|nose2|unittest|tox|hypothesis)' "$root/pyproject.toml" 2>/dev/null; then
      printf 'a test configuration in pyproject.toml'; return 0
    fi
  fi
  if [ -f "$root/setup.py" ] \
     && grep -Eq 'tests_require|test_suite|(pytest|nose2)-runner' "$root/setup.py" 2>/dev/null; then
    printf 'tests_require in setup.py'; return 0
  fi

  # 4. dotnet test projects (the same detector `_dtc_dotnet` uses).
  if command -v detect_dotnet_test_projects >/dev/null 2>&1; then
    hit="$(detect_dotnet_test_projects 2>/dev/null | grep . | head -1)"
    [ -n "$hit" ] && { printf 'the test project %s' "$hit"; return 0; }
  fi

  # 5. TEST FILES, by the naming conventions every ecosystem shares. Note this
  #    is a FILE-NAME test, never a directory test: a `test/` directory holding
  #    nothing but notes is not a test system, and saying it was is how an
  #    earlier attempt at this let an untested repo through.
  #
  #    The Swift / Scala / PHP / Perl names were MISSING, and their absence did
  #    not merely mislabel those repos — it HARD-REFUSED them at the filing
  #    gate. A real SwiftPM package (Package.swift + Tests/AppTests/
  #    AppTests.swift) read `untested` and was told to Establish Vision on a
  #    project that already exists. LCARS claims these ecosystems (`swift test`
  #    is in LCARS_TEST_RUNNER_TOKENS, `Package.swift` in
  #    LCARS_MANIFEST_FILES), so it must be able to see their tests.
  hit="$(_lcars_fnd_find "$root" 6 -type f \( \
        -name '*.test.js' -o -name '*.test.ts' -o -name '*.test.jsx' \
        -o -name '*.test.tsx' -o -name '*.test.mjs' -o -name '*.test.cjs' \
        -o -name '*.spec.js' -o -name '*.spec.ts' -o -name '*.spec.jsx' \
        -o -name '*.spec.tsx' -o -name '*.spec.mjs' \
        -o -name 'test_*.py' -o -name '*_test.py' \
        -o -name '*_test.go' -o -name '*_test.rs' \
        -o -name '*_test.rb' -o -name '*_spec.rb' \
        -o -name '*Test.java' -o -name '*Tests.java' -o -name '*Test.kt' \
        -o -name '*Test.cs' -o -name '*Tests.cs' \
        -o -name '*_test.exs' -o -name '*_test.sh' -o -name '*.test.sh' \
        -o -name '*.bats' -o -name '*.feature' \
        -o -name '*Test.swift' -o -name '*Tests.swift' -o -name '*Spec.swift' \
        -o -name '*Test.scala' -o -name '*Spec.scala' \
        -o -name '*Test.php' -o -name '*Tests.php' -o -name '*_test.php' \
        \) -print | head -1)"
  [ -n "$hit" ] && { printf 'test files (%s)' "${hit#$root/}"; return 0; }

  #    PERL, and Perl ONLY BY ITS DIRECTORY. Every name above is a CONVENTION —
  #    `foo.test.js`, `test_foo.py`, `FooTest.java` — a shape nothing but a test
  #    file wears. `.t` is not: on its own it is a template, a tuple dump, a
  #    stray script. Perl's convention is the DIRECTORY, `t/*.t`, and the
  #    extension alone claimed a root-level `CHANGELOG.t` in an untested JS repo
  #    as that repo's test system — evidence enough to OPEN the foundation gate
  #    and tell the captain his changelog proves his changes. So the parent must
  #    be a `t/` directory, which is what a Perl suite actually looks like.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "${f#$root/}" in
      t/*|*/t/*) printf 'test files (%s)' "${f#$root/}"; return 0 ;;
    esac
  done <<EV_PERL
$(_lcars_fnd_find "$root" 6 -type f -name '*.t' -print | head -40)
EV_PERL

  # 6. A conventional test directory whose FILES actually call a test API. This
  #    catches the repo whose tests are real but whose runner was never
  #    installed and whose files are named `test/foo.js` — a test system LCARS
  #    has no command for, which is `unconfigured`, not `untested`.
  #
  #    CASE. This list used to be lowercase-only and was compared with
  #    `[ -d "$root/tests" ]`, which asks the FILESYSTEM whether the directory
  #    exists — so `Tests/` (the SwiftPM convention) was found on a Mac, where
  #    APFS folds case, and missed entirely on a case-sensitive volume. The
  #    directory names are now read off the tree and matched case-insensitively
  #    in the shell, so the answer no longer depends on which disk the repo is
  #    on, and the phrase names the directory that ACTUALLY exists.
  local d base low
  for d in "$root"/* "$root"/src/*; do
    [ -d "$d" ] || continue
    base="${d##*/}"
    low="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    case "$low" in
      test|tests|spec|specs|__tests__|t) : ;;
      *) continue ;;
    esac
    hit="$(_lcars_fnd_find "$d" 3 -type f -print | head -40)"
    [ -n "$hit" ] || continue
    #    The API vocabulary is per-ecosystem, and a lowercase-only one answered
    #    for none of the languages whose test APIs are capitalised: `assert`
    #    does not match `XCTAssertEqual`, and nothing here matched
    #    `func testAdd()` or Perl's `Test::More` / `is(…)`. LCARS claims both
    #    ecosystems (`swift test` is a runner token, `Package.swift` a
    #    manifest), so reading their tests as absent HARD-REFUSED a project
    #    that already exists — the worse of the two failures.
    if printf '%s\n' "$hit" | tr '\n' '\0' \
        | xargs -0 grep -lE '(describe|it|test|context)[[:space:]]*\(|assert|unittest|#\[test\]|@Test|expect\(|XCTAssert|func[[:space:]]+[Tt]est|Test::(More|Simple|Deep|Exception)|is_deeply|(^|[^[:alnum:]_])(ok|is|isnt|cmp_ok|done_testing)[[:space:]]*\(|should[[:space:]]*[\(\{"]|@pytest|TestCase' 2>/dev/null \
        | head -1 | grep -q .; then
      printf 'tests under %s/' "${d#$root/}"; return 0
    fi
  done

  return 1
}

# lcars_repo_has_code — 0 when this repo actually holds SOURCE. The line between
# `greenfield` (nothing there) and `untested` (code, and nothing to prove it).
#
# POSITIVE evidence again, deliberately: a recognised source extension or a
# recognised build manifest, never "any file that is not a README". The denylist
# shape was tried first and it is unstable — it counts a stray `.log`, an
# editor backup or a shell stub as a codebase, and the answer then depends on
# whatever else happens to be lying in the directory. A README describing an
# idea is NOT code: that is the captain's day-zero repo and it is greenfield by
# design.
#
# NOTE the two verdicts this separates are refused IDENTICALLY by the foundation
# gate — the distinction buys WORDING (what LCARS tells the captain it found),
# not a different decision, so erring toward `greenfield` on an odd repo costs
# nothing but a slightly less specific sentence.
LCARS_SOURCE_EXTS='js|jsx|mjs|cjs|ts|tsx|vue|svelte|py|rb|go|rs|java|kt|kts|scala|cs|fs|vb|c|h|cc|cpp|hpp|m|mm|swift|php|ex|exs|erl|hs|clj|cljs|lua|dart|r|jl|pl|pm|sh|bash|zsh|sql|html|htm|css|scss|sass|less|tf|proto|graphql|gql|ipynb'
LCARS_MANIFEST_FILES='package.json|Cargo.toml|go.mod|pyproject.toml|setup.py|requirements.txt|Pipfile|Gemfile|.*\.gemspec|pom.xml|build.gradle|build.gradle.kts|.*\.csproj|.*\.sln|.*\.slnx|composer.json|mix.exs|Package.swift|CMakeLists.txt|Makefile|Dockerfile|.*\.podspec|deno.json|bun.lockb'
lcars_repo_has_code() {
  local root="${TOPLEVEL:-.}" f
  f="$(_lcars_fnd_find "$root" 4 -type f -print \
        | grep -vE '/\.git(/|$)' \
        | grep -E "\.($LCARS_SOURCE_EXTS)\$|/($LCARS_MANIFEST_FILES)\$" \
        | head -1)"
  [ -n "$f" ]
}

# lcars_test_foundation — set LCARS_TESTREADY_FOUNDATION from the status axis
# plus the evidence above. Called by lcars_test_readiness; safe to call alone
# once LCARS_TESTREADY_STATUS is set.
lcars_test_foundation() {
  LCARS_TESTREADY_FOUNDATION=""
  LCARS_TESTREADY_FOUNDATION_WHY=""
  case "${LCARS_TESTREADY_STATUS:-}" in
    ready)
      LCARS_TESTREADY_FOUNDATION="ready"
      LCARS_TESTREADY_FOUNDATION_WHY="a test command is configured and its runner resolves"
      return 0 ;;
    broken)
      # The captain configured a command; the FOUNDATION was declared and it is
      # the runner that is offline. That is today's repair case (⚡ --fix-tests),
      # not a repo without a foundation — and it must keep behaving exactly as
      # it does today.
      LCARS_TESTREADY_FOUNDATION="unconfigured"
      LCARS_TESTREADY_FOUNDATION_WHY="a test command is configured (its runner is not operational)"
      return 0 ;;
    ambiguous)
      # S147's own words: this repo HAS test systems — several of them.
      LCARS_TESTREADY_FOUNDATION="unconfigured"
      LCARS_TESTREADY_FOUNDATION_WHY="several test systems are present"
      return 0 ;;
  esac
  # `missing` and `unknown` both land here, and BOTH are re-decided on evidence.
  # `missing` is not a free pass: it is exactly what a repo carrying npm's
  # default `"test": "echo \"Error: no test specified\" && exit 1"` reads as.
  local why
  if why="$(lcars_test_system_evidence)"; then
    LCARS_TESTREADY_FOUNDATION="unconfigured"
    LCARS_TESTREADY_FOUNDATION_WHY="$why"
  elif lcars_repo_has_code; then
    LCARS_TESTREADY_FOUNDATION="untested"
    LCARS_TESTREADY_FOUNDATION_WHY="this repo has code and no test system"
  else
    LCARS_TESTREADY_FOUNDATION="greenfield"
    LCARS_TESTREADY_FOUNDATION_WHY="this repo is empty"
  fi
  return 0
}

# lcars_test_readiness — the ONE entry point every surface calls. Runs the
# status axis (unchanged) and then the foundation axis, so a caller that only
# ever read LCARS_TESTREADY_STATUS is byte-identical and a caller that needs the
# foundation gets it without a second pass over the repo.
lcars_test_readiness() {
  LCARS_TESTREADY_FOUNDATION=""
  LCARS_TESTREADY_FOUNDATION_WHY=""
  lcars_test_readiness_status "$@"
  lcars_test_foundation
  return 0
}

# stack_uses_native_isolation <stack> — 0 when this stack's Implement gate legs
# are scoped by the RUNNER's own flags rather than by pointing it at an external
# $LCARS_TESTS_DIR quarantine (`cargo test --test <stem>`, `go test -run`, an
# explicit rspec/minitest file, `dotnet test --filter`). These runners are
# compiled/loaded per crate/package/project and simply cannot be aimed at a
# detached directory, which is why they took the native path in the first place.
#
# MUST STAY IN STEP with `stack_is_native` in skills/lcars-run/run.sh — that is
# the gate-side authority; this is the init/update-side reader of the same fact
# (run.sh does not source this file). Adding a stack to one means adding it to
# the other.
stack_uses_native_isolation() { # stack → 0 = native isolation
  case "${1:-}" in rust|go|ruby|dotnet) return 0 ;; *) return 1 ;; esac
}

# lcars_stack_alternatives <stack> — the candidate COMMANDS when a SINGLE stack
# is present but cannot pin ONE runner, newline-separated; empty when the stack
# has no such shape (which is every stack that never reaches here with a real
# choice to make). Today: dotnet with several test projects.
#
# Ruby has the same disease — an rspec (spec/) AND a minitest (test/ + Rakefile)
# layout without a decisive Gemfile signal also seeds nothing and reads as
# greenfield — and is deliberately LEDGERED rather than changed here: S145's
# shipped init/update output is regression-locked by tests/stack-ruby.test.sh and
# the S147 brief scopes this fix to the dotnet path. Same cure when it is due.
lcars_stack_alternatives() { # stack → candidate commands, one per line
  case "${1:-}" in
    dotnet)
      local projs n p
      projs="$(detect_dotnet_test_projects | grep . || :)"
      n="$(printf '%s' "$projs" | grep -c . || :)"
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      [ "$n" -ge 2 ] || return 0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf 'dotnet test %s\n' "$p"
      done <<DN_ALT
$projs
DN_ALT
      ;;
    *) : ;;
  esac
}

# lcars_readiness_line — render the ONE human status line for the verdict the
# globals above carry. Ship-status voice (never a config lecture):
#   ready    → EMPTY (ready repos are silent everywhere — zero chrome drift)
#   broken/  → the REPAIR voice: ⚠ TEST SYSTEMS OFFLINE + the one-click fix verb
#   missing
#   unknown  → the BOOTSTRAP voice: a greenfield repo is EXPECTED, not an alarm —
#              reads as status, never an action item.
#   ambiguous→ (S147) the CHOOSE voice: this repo HAS test systems, several of
#              them, and LCARS will not pick for the captain. Never the
#              bootstrap voice (it is not greenfield) and never the bare repair
#              voice (nothing is broken) — it points at the same ⚡ fix verb.
# The unready voices must NEVER blur (captain ruling, S146).
lcars_readiness_line() {
  case "${LCARS_TESTREADY_STATUS:-}" in
    broken)
      # S185 fix round 1 — two shapes of `broken`, and naming the first token of
      # a command that does not PARSE would blame the wrong thing ("runner npx
      # not operational" about a perfectly good npx).
      if [ "${LCARS_TESTREADY_BROKEN_WHY:-}" = unparseable ]; then
        printf '⚠ TEST SYSTEMS OFFLINE — the configured testCommand is not a command any shell can parse (%s); missions cannot be proof-gated. Repair: lcars update --test-command '"'"'<command>'"'"'\n' \
          "$LCARS_TESTREADY_TESTCMD"
        return 0
      fi
      printf '⚠ TEST SYSTEMS OFFLINE — testCommand runner "%s" not operational; missions cannot be proof-gated. Repair: lcars update --fix-tests\n' \
        "$(printf '%s' "$LCARS_TESTREADY_TESTCMD" | awk '{print $1}')"
      ;;
    missing)
      # S183 fix round 1 (D3, the CLI half). `missing` means DETECTION has a
      # candidate — and `_dtc_js` claims any package.json carrying a "test" key,
      # so npm's default `echo "Error: no test specified" && exit 1` produces
      # one over a repo with no test system at all. Offering that placeholder as
      # "the detected candidate" with a ⚡ --fix-tests repair, on a repo whose
      # ▦ FILE MISSION the board has LOCKED and whose next line says to start
      # with Establish Vision, is one repo told two different stories. The
      # foundation is the honest axis, so it decides here too.
      case "${LCARS_TESTREADY_FOUNDATION:-}" in
        untested)
          printf '◇ NO TEST SYSTEM FOUND — this repo has code and nothing to prove it with (the `test` script here names no test runner); LCARS establishes the foundation before a normal mission runs (see Establish Vision).\n'
          return 0 ;;
        greenfield)
          printf '◇ NO TEST SYSTEMS FOUND — a greenfield repo; the first mission here is an initialization mission, and its engineering crew will establish them. Start it with Establish Vision.\n'
          return 0 ;;
      esac
      printf '⚠ TEST SYSTEMS OFFLINE — no test command configured (detected candidate: %s); missions cannot be proof-gated. Repair: lcars update --fix-tests\n' \
        "$LCARS_TESTREADY_SUGGESTION"
      ;;
    unknown)
      # S183 — the `unknown` STATUS is three different repos, and until now all
      # three were told they were greenfield. The FOUNDATION axis is what tells
      # them apart, so it is what this line branches on. The greenfield wording
      # is UNCHANGED and still shipped — for the repo it is actually true of.
      case "${LCARS_TESTREADY_FOUNDATION:-greenfield}" in
        unconfigured)
          # S299 fix round 1 — THIS LINE USED TO ASSERT THE OPPOSITE OF WHAT THE
          # DETECTOR HAD JUST DECIDED. The foundation axis claims a test system
          # from the mere PRESENCE of an artifact (deliberately, and ledgered:
          # it feeds the FILING gate, where a false negative kills a mission
          # before it starts). So a repo whose only test declaration is a
          # recipe-less `test:` target reached this branch and was told it HAS a
          # test system — the exact claim the inert filter exists to deny — and
          # was then handed `--test-command` as the repair. MEASURED: a captain
          # who followed that prescription got `✓ TEST SYSTEMS ONLINE` and a
          # passing probe for a `make test` that runs nothing. The product's own
          # advice walked him back into the bug.
          #
          # The right words already existed one function away. Nothing about the
          # ROUTE changes here (filing is still allowed, and the escape hatch is
          # still there for someone who knows a runner LCARS missed) — only what
          # the captain is told he has.
          if [ -n "${LCARS_TESTREADY_INERT_WHY:-}" ]; then
            printf '⚠ TEST SYSTEMS OFFLINE — the test configuration at the repo root cannot run: %s; missions cannot be proof-gated. Repair: establish a test runner that actually runs (or, if one is already here that LCARS missed, name it: lcars update --test-command '"'"'<command>'"'"').\n' \
              "$LCARS_TESTREADY_INERT_WHY"
            return 0
          fi
          printf '⚠ TEST SYSTEMS OFFLINE — this repo HAS a test system (%s) but no test command is configured; missions cannot be proof-gated. Repair: lcars update --test-command '"'"'<command>'"'"'\n' \
            "${LCARS_TESTREADY_FOUNDATION_WHY:-detected}"
          ;;
        untested)
          # S299 fix round 1 — THE RESTORED CLAUSE. Before the inert filter, a
          # repo carrying npm's generated placeholder detected a CANDIDATE, so
          # it landed in `missing` above and read "(the `test` script here names
          # no test runner)". The filter stopped emitting that candidate, which
          # is right, and the repo fell through to `unknown` — where the same
          # sentence had no parenthetical at all, and the captain lost the one
          # clause that told him which file was the problem. It is the same
          # phrase, now sourced from the filter rather than hard-coded, so it
          # names whichever artifact was actually refused.
          printf '◇ NO TEST SYSTEM FOUND — this repo has code and nothing to prove it with%s; LCARS establishes the foundation before a normal mission runs (see Establish Vision).\n' \
            "${LCARS_TESTREADY_INERT_WHY:+ ($LCARS_TESTREADY_INERT_WHY)}"
          ;;
        *)
          # S183 KEPT THE VOICE AND FIXED THE PROMISE. The old line ended "the
          # first mission's engineering crew will establish them" — the promise
          # nothing downstream kept, and one `lcars file` now refuses outright.
          # It is still the calm BOOTSTRAP voice (a greenfield repo is expected,
          # not an alarm) and it still names the crew that establishes the test
          # systems; it just names the RIGHT first mission — an INITIALIZATION
          # mission, launched from Establish Vision, which is the only kind this
          # repo can take until the foundation lands.
          printf '◇ NO TEST SYSTEMS FOUND — a greenfield repo; the first mission here is an initialization mission, and its engineering crew will establish them. Start it with Establish Vision.\n'
          ;;
      esac
      ;;
    # LEDGERED (recorded, not fixed): `$LCARS_TESTREADY_STACKS` is a list of
    # STACK IDS for a multi-stack repo — "(rust,js)" reads perfectly — but a list
    # of .csproj PATHS when one stack cannot pin its runner, and
    # "MULTIPLE TEST SYSTEMS DETECTED (One.Tests/One.Tests.csproj,…)" reads
    # awkwardly. It is accurate and it is what the captain must choose between,
    # so it ships; a per-shape phrasing (stacks vs projects) is the tidier fix
    # whenever this line is next opened.
    ambiguous)
      printf '⚠ MULTIPLE TEST SYSTEMS DETECTED (%s) — LCARS will not choose for you; missions cannot be proof-gated until one is selected. Select: lcars update --fix-tests\n' \
        "$LCARS_TESTREADY_STACKS"
      ;;
    *) : ;;  # ready (or uncomputed) → silent
  esac
}

# lcars_config_set_or_add_string — the sanctioned-writer primitive: overwrite a
# top-level string key IN PLACE (lcars_config_set_string), or — when the key is
# absent from an older config — INSERT it as the first key after the opening
# brace. All text outside the targeted value is preserved byte-for-byte.
# S309 fix round 1, D6 — OPTIONAL <after-key>: insert the new key's line
# immediately AFTER that key's line instead of at the top. `lcars init` writes
# `workerBin` straight after `model`, so `lcars update --engine` adding it at
# the top meant the first init/update afterwards REORDERED one key (identical
# values, one shot, then stable). Harmless, and still a diff in a file the
# captain reads; a sibling writer can now place a key in the same slot.
#
# IT FALLS BACK RATHER THAN RISK THE FILE. The <after-key> is used only when its
# value both EXISTS and is followed by a comma — inserting a comma-terminated line after
# the file's LAST key would produce invalid JSON. Anything else takes the
# historical path (first key after the opening brace), where the inserted line's
# own comma is always correct.
lcars_config_set_or_add_string() {
  _lcars_config_json set-string "$1" "$2" "$3" "${4:-}"
}

# lcars_config_set_or_add_raw — the same primitive for a RAW (unquoted) JSON
# value: an object, an array, a number, true/false/null. Replaces the full value,
# including multiline objects, and validates input and read-back before replace.
lcars_config_set_or_add_raw() {
  _lcars_config_json set-raw "$1" "$2" "$3" ""
}

# lcars_config_get_raw — the RAW text of a top-level key's value: an object on
# one line, a number, true/false/null. Multiline values are compacted; malformed
# JSON fails explicitly. Empty when absent. The string reader
# above cannot answer for an object, and a surface that showed `numberOne` by
# re-deriving it from somewhere else would be inferring a fact its producer
# already recorded.
lcars_config_get_raw() {
  [ -f "$1" ] || return 0
  _lcars_config_json get-raw "$1" "$2"
}

# === S176: THE PRD's REQUIRED FIELDS, IN EITHER SHAPE ======================
#
# WHAT WAS MEASURED (DX-Scorecard, lcars-20260827-001). The captain designed in
# the holodeck, completed a FULL Align grill, sent it for costing — and file.sh
# refused, because the Align agent wrote the PRD with MARKDOWN HEADINGS
# (`Mission: …` on a bare line, then `Type` / `Goal` / `Acceptance Criteria` /
# `Out of Scope` / `Constraints` as headings with their values beneath) instead
# of the bold inline labels the greps demanded. The heading form failed ALL SIX.
# He lost two completed grill sessions to it.
#
# A PRD is what it SAYS, not which of two ordinary markdown spellings it says it
# in. So both are accepted here, in ONE place, and — this is the whole risk of
# the change — VALIDATION AND EXTRACTION READ THE SAME FUNCTION. Accepting a
# heading-form PRD and then deriving an EMPTY title or type would replace a loud
# failure with a silent one, which is strictly worse than the refusal it
# replaces. There is no second parser to drift from this one.
#
#   SHAPE 1 (bold inline, unchanged):  **Type:** feature
#   SHAPE 2 (heading):                 ## Type        |  # Mission: <title>
#                                      feature
#
# Shape 2 is deliberately TIGHT: the label must OWN its line — optional #'s,
# optional emphasis, the label, and then either end-of-line or a colon. Prose
# that merely BEGINS with the word ("Constraints on the build are…") is not a
# section, and is not matched.

# THE SIX SECTIONS every PRD must declare, in the order file.sh checks them.
# ONE list: the reader below stops a heading-form value scan at any of them, so
# a labelled-but-EMPTY section can never silently absorb the next section's
# heading as its value. (SKILL.md's template spells the same six.)
# "Mission title" is an alias of "Mission" for both validation and extraction.
LCARS_PRD_LABELS='Mission|Mission title|Type|Goal|Acceptance Criteria|Out of Scope|Constraints'

# _lcars_prd_read <prd-path> <label> <has|value>
#   has   -> exit 0 when the PRD declares the label in EITHER shape
#   value -> print the label's value ("" when it has none)
_lcars_prd_read() {
  LCARS_PRD_LABELS="$LCARS_PRD_LABELS" \
  "${LCARS_PYTHON_BIN:-python3}" - "$1" "$2" "$3" <<'S176_PY'
import os, re, sys
path, label, mode = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as fh:
        text = fh.read()
except OSError:
    sys.exit(1)
lines = text.replace("\r\n", "\n").split("\n")
lab = r"Mission(?: title)?" if label.lower() in ("mission", "mission title") else re.escape(label)

# SHAPE 1 — the bold inline label, matched where the old greps matched it
# (anywhere on the line), so every PRD that filed yesterday files today.
BOLD = re.compile(r".*\*\*[ \t]*" + lab + r"[ \t]*:[ \t]*\*\*[ \t]*(.*)$", re.I)
# SHAPE 2 — the label OWNS the line: an optional markdown heading marker (the
# ONLY thing that may be indented), optional emphasis, the label, then either
# end-of-line or a colon with an optional value. Prose that merely BEGINS with
# the word ("Constraints on the build are…") is not a section and is not
# matched, and neither is a bullet's indented continuation.
HEAD = re.compile(
    r"^(?:[ \t]{0,3}#{1,6}[ \t]*)?[*_]{0,3}" + lab +
    r"[ \t]*[*_]{0,3}[ \t]*(?::[ \t]*(.*?))?[ \t]*$", re.I)
# Lines that are themselves a label/heading — never another label's value.
STOP = [x for x in os.environ.get("LCARS_PRD_LABELS", "").split("|") if x]
NEXT_LABEL = re.compile(
    r"^[ \t]{0,3}(?:#{1,6}[ \t]|\*\*[^*]+:\*\*)"
    + (r"|^(?:[ \t]{0,3}#{1,6}[ \t]*)?[*_]{0,3}(?:"
       + "|".join(re.escape(x) for x in STOP)
       + r")[ \t]*[*_]{0,3}[ \t]*(?::.*)?$" if STOP else ""), re.I)


def clean(v):
    return re.sub(r"^[*_`]+|[*_`]+$", "", (v or "").strip()).strip()


for ln in lines:
    m = BOLD.match(ln)
    if m:
        if mode == "has":
            sys.exit(0)
        sys.stdout.write(clean(m.group(1)))
        sys.exit(0)

for i, ln in enumerate(lines):
    m = HEAD.match(ln)
    if not m:
        continue
    if mode == "has":
        sys.exit(0)
    v = clean(m.group(1))
    if v:
        sys.stdout.write(v)
        sys.exit(0)
    # No value on the label's own line — take the first non-blank line under it,
    # unless that line is itself a label (an empty section stays EMPTY, and its
    # caller dies loudly, rather than swallowing the next heading as a value).
    for nxt in lines[i + 1:]:
        if not nxt.strip():
            continue
        if NEXT_LABEL.match(nxt):
            break
        sys.stdout.write(clean(nxt))
        break
    sys.exit(0)

sys.exit(1 if mode == "has" else 0)
S176_PY
}

# lcars_prd_has_field <prd-path> <label> -> 0 when the PRD declares it.
lcars_prd_has_field() { _lcars_prd_read "$1" "$2" has; }

# lcars_prd_field <prd-path> <label> -> the label's value on stdout.
lcars_prd_field() { _lcars_prd_read "$1" "$2" value; }

# === S175: THE BRIEF'S OWN OPEN QUESTIONS SURVIVE THE ALIGN → PRD BOUNDARY ===
#
# WHAT WAS MEASURED (lcars-20260814-001). Its `prd.md` has exactly two headings:
# `# Mission:` and `## Attached files`. The concept doc it was filed from carried
# ~14 unsettled items, and NOT ONE survived as a question. The PRD simply ASSERTS
# answers — it states the Carried-pill rule flatly, though "what makes a KPI
# carried?" was open in the brief. Known-unknowns became silent certainties, and
# the captain met each decision for the first time as a shipped screen.
# `attachment-02.md:140` asked what "Preview" and "View" actually do; it shipped
# unanswered, a preview screen was built by fiat, and that screen is where the
# composite-KPI cell came out scrambled. The un-drawn surface and the unanswered
# question were the same hole from two sides.
#
# THE GATE IS DETERMINISTIC AND IT COUNTS, IT DOES NOT JUDGE. Every bullet under
# the concept doc's `## Open questions` must be findable in the PRD. It does NOT
# read whether the PRD answered it well, whether the wording is right, or whether
# a resolution is correct — that is the captain's, at Align. This project has
# lost whole sessions to classifiers (S156 14/14 → 5/14 on a reworded corpus,
# S147 four generations of a source parser); the decision moves to a DECLARATION
# and the harness only checks the declaration is there.
#
# ALIGN MAY RESOLVE ONE — that is the ideal path, and a PRD that records the
# question with its answer passes exactly as one that records it still-open does.
# What it may NOT do is drop it, which is the only thing this refuses.
#
# THE EMPTY-BUCKET RULE APPLIES BOTH WAYS. A brief with ZERO open questions must
# produce NO section — the captain reads a heading as a list of things he has to
# deal with, and one with nothing behind it is a line of his brief spent on
# nothing. So an invented section is refused too.
LCARS_PRD_QUESTIONS_HEADING='Open questions from the design session'

# lcars_concept_open_questions <path…> -> one open question per line.
# Reads `## Open questions` off any DOC attachment (the concept doc the holodeck
# files beside the mockup). EMPTY for every mission without one, which makes the
# gate below a total no-op — a mission with no design session is untouched.
lcars_concept_open_questions() {
  [ "$#" -gt 0 ] || return 0
  "${LCARS_PYTHON_BIN:-python3}" - "$@" <<'S175_PY'
import os, re, sys
HEAD = "Open questions"


def section(text, head):
    want = re.sub(r"[^a-z0-9]+", " ", head.lower()).strip()
    out, lvl = [], None
    for ln in text.replace("\r\n", "\n").split("\n"):
        m = re.match(r"^(#{1,6})\s+(.*)$", ln)
        if m:
            name = re.sub(r"[^a-z0-9]+", " ", m.group(2).lower()).strip()
            if lvl is None:
                if name == want or name.startswith(want + " "):
                    lvl = len(m.group(1))
                continue
            if len(m.group(1)) <= lvl:
                break
            out.append(ln)      # a DEEPER heading is part of this section's body
            continue
        if lvl is not None:
            out.append(ln)
    return "\n".join(out)


BULLET = re.compile(r"^([-*+]|\d+[.)])\s+")


def items(body):
    """Bullets, with their CONTINUATION LINES joined back on.

    Measured on the real brief: every one of its questions wraps across two
    physical lines. Counting lines instead of bullets turns two questions into
    four half-sentences, and then no PRD on earth can contain them verbatim.
    """
    got, cur = [], None
    for ln in body.split("\n"):
        t = ln.strip()
        if not t:
            continue
        m = BULLET.match(t)
        if m:
            if cur:
                got.append(" ".join(cur.split()))
            cur = t[m.end():]
        elif cur is not None:
            cur = cur + " " + t
    if cur:
        got.append(" ".join(cur.split()))
    return got


seen, out = set(), []
for p in sys.argv[1:]:
    if os.path.splitext(p)[1].lower() not in (".md", ".markdown", ".txt", ".rst"):
        continue
    try:
        with open(p) as fh:
            text = fh.read()
    except OSError:
        continue
    # BOTH homes the contract gives an unsettled thing, because `_CONCEPT_CONTRACT`
    # splits them ON PURPOSE (ONE HOME EACH) and the captain must not read the
    # same thing twice: `## Open questions`, and bucket 2 of `## WHAT IT MUST DO`
    # — "Implied by the mockup, not yet settled … Write each as a QUESTION".
    # MEASURED on lcars-20260814-001: 2 in the first, 12 in the second. Reading
    # only the first would carry 2 of its 14 unsettled items and call it done.
    bodies = [section(text, HEAD)]
    must = section(text, "WHAT IT MUST DO")
    if must:
        bodies.append(section(must, "2. Implied by the mockup"))
        bodies.append(section(must, "Implied by the mockup"))
    for body in bodies:
        for it in items(body):
            if it not in seen:
                seen.add(it)
                out.append(it)
sys.stdout.write("\n".join(out) + ("\n" if out else ""))
S175_PY
}

# lcars_prd_questions_gate <prd> <attachment…> -> 0 when the PRD accounts for
# every open question the brief left unsettled, non-zero with a message on
# stderr naming exactly which ones evaporated (or which section was invented).
#
# ── FIX ROUND 1 / D3: THE GATE WAS BYPASSED BY THE FAILURE IT EXISTS TO STOP ──
# The first cut asked two separate questions — does the heading exist, and does
# each question's text appear ANYWHERE in the PRD — and never that the two were
# related. So a PRD whose open-questions section read "None outstanding — all
# settled during the grill." PASSED, because the questions appeared in a quoted
# `## Background from the design session` block higher up, followed by
# "**Decision:** month-only." Quoting the brief in a context block is a NORMAL
# thing for an Align worker to do, so this was not an exotic bypass: it is the
# most likely shape of the exact evaporation the gate was built to catch. The
# questions must now be found INSIDE the section.
#
# ── FIX ROUND 1 / D7: A RESOLVED QUESTION MAY BE REPHRASED ────────────────
# Verbatim-only matching was enforced with a hard refusal, so an Align worker
# that GENUINELY resolved a question with the captain and wrote the resolution
# in its own words killed the filing outright. Resolving is the ideal path; the
# gate must not punish it. So a section entry marked RESOLVED that matches no
# question verbatim ACCOUNTS FOR one unmatched question — the count is what is
# checked, not the prose.
#
# WHAT THAT DOES NOT BUY, said out loud: a worker could write N bogus
# "RESOLVED: …" entries and satisfy the count. That is an explicit lie ("settled
# with the captain") rather than the silent evaporation this round targets, and
# no syntactic check on a self-declared field makes the field honest — S174
# spent three rounds proving that. This is a floor.
lcars_prd_questions_gate() {
  local prd="$1"; shift
  [ -f "$prd" ] || return 0
  local qf; qf="$(mktemp)"
  lcars_concept_open_questions "$@" > "$qf"
  local rc=0
  "${LCARS_PYTHON_BIN:-python3}" - "$prd" "$LCARS_PRD_QUESTIONS_HEADING" "$qf" <<'S175_PY' || rc=$?
import os, re, sys
prd_path, heading, qfile = sys.argv[1], sys.argv[2], sys.argv[3]
with open(qfile) as fh:
    qs = [ln.strip() for ln in fh if ln.strip()]
with open(prd_path) as fh:
    prd = fh.read()
want = re.sub(r"[^a-z0-9]+", " ", heading.lower()).strip()

occurrences = []
for number, ln in enumerate(prd.replace("\r\n", "\n").split("\n"), 1):
    m = re.match(r"^(#{1,6})\s+(.*)$", ln)
    if m and re.sub(r"[^a-z0-9]+", " ", m.group(2).lower()).strip().startswith(want):
        occurrences.append((number, ln))
if len(occurrences) > 1:
    sys.stderr.write(
        "PRD has duplicate '%s' headings. Keep ONE section containing every "
        "question, not a copied idea section plus an appended hand-off section. "
        "Occurrences:\n%s\n"
        % (heading, "\n".join("  line %d: %s" % row for row in occurrences)))
    sys.exit(1)

if os.environ.get("LCARS_PRD_QUESTIONS_UNIQUENESS_ONLY") == "1":
    sys.exit(0)

section, lvl, found = [], None, False
for ln in prd.replace("\r\n", "\n").split("\n"):
    m = re.match(r"^(#{1,6})\s+(.*)$", ln)
    if m:
        name = re.sub(r"[^a-z0-9]+", " ", m.group(2).lower()).strip()
        if lvl is None:
            if name.startswith(want):
                lvl, found = len(m.group(1)), True
            continue
        if len(m.group(1)) <= lvl:
            lvl = None
            continue
        section.append(ln)
        continue
    if lvl is not None:
        section.append(ln)
has_section = found

if not qs:
    if has_section:
        sys.stderr.write(
            "PRD carries a '%s' section, but the design brief left NO question "
            "open. An empty bucket is a heading the captain reads as a list of "
            "things he has to deal with; delete the section.\n" % heading)
        sys.exit(1)
    sys.exit(0)
if not has_section:
    sys.stderr.write(
        "PRD is missing the '%s' section. The design brief left %d question(s) "
        "unsettled, and a PRD that does not carry them forward turns every one "
        "into an assertion nobody was asked about — measured on "
        "lcars-20260814-001, where ~14 unsettled items became silent certainties "
        "and the captain met each as a shipped screen. Carry each one AS WHAT IT "
        "IS: still open, or resolved with the captain and recorded as resolved. "
        "Missing:\n%s\n"
        % (heading, len(qs), "\n".join("  - " + q for q in qs)))
    sys.exit(1)

BULLET = re.compile(r"^([-*+]|\d+[.)])\s+")
entries, cur = [], None
for ln in section:
    t = ln.strip()
    if not t:
        continue
    m = BULLET.match(t)
    if m:
        if cur:
            entries.append(" ".join(cur.split()))
        cur = t[m.end():]
    elif cur is not None:
        cur = cur + " " + t
    else:
        entries.append(" ".join(t.split()))
if cur:
    entries.append(" ".join(cur.split()))


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


# D3: matched INSIDE the section, never anywhere in the file.
section_text = norm(" \n ".join(entries))
missing = [q for q in qs if norm(q) not in section_text]

# D7: a RESOLVED entry that matched nothing verbatim accounts for one of them.
EMPH = re.compile(r"^[*_`]+|[*_`]+$")
RESOLVED = re.compile(r"(?i)^resolved\b")
spare = 0
for e in entries:
    lead = EMPH.sub("", e).lstrip()
    if not RESOLVED.match(lead):
        continue
    if any(norm(q) in norm(e) for q in qs):
        continue          # it already matched verbatim; it is not spare
    spare += 1

if len(missing) > spare:
    unaccounted = missing[spare:] if spare else missing
    sys.stderr.write(
        "PRD drops %d of the design brief's %d open question(s) from its '%s' "
        "section. Each must be carried forward there as a question — still open, "
        "or resolved with the captain and recorded as resolved. It may NOT "
        "quietly become an assertion, and quoting it elsewhere in the PRD does "
        "not count: the section is what the captain and the Plan Stage read. "
        "The question text must appear VERBATIM for a text match (line wrapping "
        "is fine); a paraphrase of a STILL OPEN question does not match. A "
        "declared RESOLVED entry may instead account for a settled question. "
        "For example, copy this correct line:\n  - STILL OPEN: %s\n"
        "Or retain that question text after `RESOLVED with the captain:` and "
        "append ` — DECIDED: <the captain's answer>`.\nMissing:\n%s\n"
        % (len(unaccounted), len(qs), heading,
           unaccounted[0],
           "\n".join("  - " + q for q in unaccounted)))
    sys.exit(1)
S175_PY
  rm -f "$qf"
  return "$rc"
}

# ===========================================================================
# S232 — THE DRIVE RECORD: one file, written by the driver, read by everyone
# ===========================================================================
#
# THE WEEKEND DEFECT. `lcars answer respond` clears a gate and then hands back to
# the driver (`run.sh drive --mission <id>`, respond.sh's S180 resume). Nothing
# anywhere recorded that a drive was ALREADY running for that mission, so an
# answer given while a driver was mid-flight started a SECOND driver on top of
# the live one (evidence/lcars-feedback.jsonl #6). run.sh's own `driver.lock`
# made the second one a clean no-op once it got as far as `cmd_drive`, but by
# then respond had already told the captain it was resuming, and neither respond
# nor `lcars` could say anything useful before spawning.
#
# RECORD, DON'T INFER (ORCHESTRATION.md § infer-vs-record; it cost S147, S156 and
# S188 a round each). The producer — the driver itself — writes the fact down the
# moment it is true: `$MISSION_DIR/drive.pid`, two lines, its pid and when it
# started. `pgrep run.sh` was the rejected alternative: it reconstructs from a
# command line that a wrapper, a worktree or a second repo can each make lie.
#
# The RECORD LIVES HERE, not in run.sh, because there are two consumers besides
# the producer — `lcars respond` and the `lcars` auto-advance router — and two
# readers of one file is exactly how the record's format drifts. One home.
#
# A STALE record reads as ABSENT. A driver killed with SIGKILL, or a machine that
# lost power, leaves the file behind; a check that treated that as "live" would
# wedge the mission for good. `lcars_drive_record_start` overwrites
# unconditionally, so staleness never needs sweeping to self-heal.

# The record's path for a mission dir. One place spells it.
lcars_drive_record_path() { # <mission-dir>
  printf '%s/drive.pid' "${1:-}"
}

# lcars_drive_record_start <mission-dir> [pid] [iso-stamp]
# Write the record. Called by the driver the instant it owns the mission.
# `$$` is deliberately the DEFAULT rather than the only source: run.sh reaches
# this through a subshell `source`, where `$$` is still the parent shell's pid,
# and the caller passing its pid explicitly keeps that from being a subtlety
# anybody has to remember. Never fatal — a driver must not fail to drive because
# it could not write a note about itself.
lcars_drive_record_start() { # <mission-dir> [pid] [iso]
  local d="${1:-}" p="${2:-$$}" t="${3:-}"
  [ -n "$d" ] && [ -d "$d" ] || return 1
  [ -n "$t" ] || t="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n%s\n' "$p" "$t" >"$(lcars_drive_record_path "$d")" 2>/dev/null || return 1
  return 0
}

# lcars_drive_record_clear <mission-dir> [pid]
# Remove the record IFF it is OURS — the same posture as release_driver_lock in
# run.sh, and for the same reason: a process that found someone else's live
# record must never delete it on its way out.
lcars_drive_record_clear() { # <mission-dir> [pid]
  local d="${1:-}" p="${2:-$$}" f own
  [ -n "$d" ] || return 0
  f="$(lcars_drive_record_path "$d")"
  [ -f "$f" ] || return 0
  own="$(sed -n 1p "$f" 2>/dev/null)"
  [ "$own" = "$p" ] || return 0
  rm -f "$f" 2>/dev/null || true
  return 0
}

# lcars_drive_live <mission-dir>
# THE ONE CHECK both consumers make. Prints "<pid>\t<started-at>" and returns 0
# when a LIVE driver holds this mission; prints nothing and returns 1 when there
# is no record, the record is unreadable, or its pid is gone (stale ⇒ absent).
# Pure READ: it never deletes, so a caller can consult it without side effects.
lcars_drive_live() { # <mission-dir>
  local d="${1:-}" f p t
  [ -n "$d" ] || return 1
  f="$(lcars_drive_record_path "$d")"
  [ -f "$f" ] || return 1
  p="$(sed -n 1p "$f" 2>/dev/null)"
  t="$(sed -n 2p "$f" 2>/dev/null)"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  printf '%s\t%s\n' "$p" "$t"
  return 0
}

# lcars_drive_live_line <mission-dir> <mission-id>
# The SENTENCE both consumers open with, so the captain reads the same words from
# `lcars respond` and from bare `lcars`; each adds its own tail. Prints nothing
# and returns 1 when no drive is live.
lcars_drive_live_line() { # <mission-dir> <mission-id>
  local rec pid at tab
  tab="$(printf '\t')"
  rec="$(lcars_drive_live "${1:-}")" || return 1
  pid="${rec%%${tab}*}"; at="${rec#*${tab}}"
  printf 'a drive is already running for %s (pid %s since %s)' \
    "${2:-}" "$pid" "${at:-an unknown time}"
  return 0
}
