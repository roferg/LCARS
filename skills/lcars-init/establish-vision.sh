#!/usr/bin/env bash
#
# establish-vision.sh — ESTABLISH VISION, the day-zero front door (S184).
#
# ┌────────────────────────────────────────────────────────────────────────┐
# │ ONE machinery, BOTH front doors. `lcars` on the CLI and the viewscreen │
# │ board call THIS script for every fact, every word and every file they  │
# │ produce, so the same answers file a byte-identical mission whichever   │
# │ door the captain walked through. There is no second implementation.    │
# └────────────────────────────────────────────────────────────────────────┘
#
# WHAT THIS IS. S183 made a repo with no test foundation REFUSE a normal
# mission. That is the backstop and it does not change. This is what the captain
# SEES instead of the refusal: an invitation. Say what you want to build; LCARS
# grills you (the EXISTING Align machinery, pointed at a PROJECT instead of a
# feature — never a second interviewer), RECOMMENDS a stack with its reasons,
# which are yours to override, and files an INITIALIZATION MISSION whose whole
# scope is the FOUNDATION.
#
# THE SCOPE FENCE IS THE POINT, and it is enforced in THREE places because a
# model will happily talk its way out of any one of them:
#   1. `--brief`  states the fence in the GRILL'S OWN WORDS (the prompt).
#   2. `--prd`    ASSEMBLES the PRD from a fixed template here in the harness.
#      The grill supplies the stack, the reasons and the one thin slice; it
#      never supplies the scope. A vision that specifies twelve features has
#      FAILED, so the twelve features cannot reach the PRD by construction.
#   3. `--write-vision` puts the deferred features in the VISION DOC, which is
#      durable, which later missions read, and which is not the mission.
#
# THE NARROW RULE (measured 2026-09-05 on the captain's own machine). The front
# door REPLACES the board only when there is NOTHING TO PUT ON THE BOARD —
# `frontDoor` is true only when the verdict locks AND this repo holds zero
# missions. `Flappy-Bird` is an initialized repo, verdict `untested`, with TWO
# real missions on its board; keying the front door off the verdict alone would
# have deleted that board. Where the board can still render, S183's lock stays
# in force on it, exactly as today.
#
# Usage:
#   establish-vision.sh --facts
#       {"foundation","foundationWhy","stack","stackLabel","sourceFiles",
#        "testRunner","missions","frontDoor"} — the FOUND panel's numbers, from
#       REAL detection. Exit 0 always (a report, never a gate).
#
#   establish-vision.sh --brief
#       The foundation brief: the scope fence in the grill's own words, keyed to
#       this repo's verdict (the `untested` variant does NOT re-ask what we are
#       building — it can see).
#
#   establish-vision.sh --prd --idea <f> --stack <s> [--reasons <f>]
#                       [--deferred <f>] [--slice <s>] [--title <s>]
#       The assembled, foundation-scoped PRD on stdout. Deterministic.
#
#   establish-vision.sh --write-vision …same args…
#       Writes .git/lcars/vision.md (the durable project vision). Prints its path.
#
#   establish-vision.sh --file …same args…
#       --write-vision, then files the INITIALIZATION mission through the ONE
#       sanctioned filer (`lcars file --prd --initialization`). Prints
#       `MISSION_ID=<id>`.
#
# Exit: 0 ok · 1 bad usage / a filing that failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lcars-common.sh
. "$SCRIPT_DIR/lcars-common.sh"

FILE_SH="${LCARS_FILE_SCRIPT:-$SCRIPT_DIR/../lcars-file/file.sh}"

die() { printf 'lcars establish-vision: %s\n' "$1" >&2; exit 1; }

MODE=""
IDEA_SRC=""; STACK=""; REASONS_SRC=""; DEFERRED_SRC=""; SLICE=""; TITLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --facts)        MODE="facts"; shift ;;
    --brief)        MODE="brief"; shift ;;
    --prd)          MODE="prd"; shift ;;
    --write-vision) MODE="vision"; shift ;;
    --file)         MODE="file"; shift ;;
    --idea)      IDEA_SRC="${2:-}"; shift 2 ;;
    --idea=*)    IDEA_SRC="${1#--idea=}"; shift ;;
    --stack)     STACK="${2:-}"; shift 2 ;;
    --stack=*)   STACK="${1#--stack=}"; shift ;;
    --reasons)   REASONS_SRC="${2:-}"; shift 2 ;;
    --reasons=*) REASONS_SRC="${1#--reasons=}"; shift ;;
    --deferred)  DEFERRED_SRC="${2:-}"; shift 2 ;;
    --deferred=*) DEFERRED_SRC="${1#--deferred=}"; shift ;;
    --slice)     SLICE="${2:-}"; shift 2 ;;
    --slice=*)   SLICE="${1#--slice=}"; shift ;;
    --title)     TITLE="${2:-}"; shift 2 ;;
    --title=*)   TITLE="${1#--title=}"; shift ;;
    *) die "unknown option \"$1\" — use --facts, --brief, --prd, --write-vision or --file." ;;
  esac
done
[ -n "$MODE" ] || die "no mode given — use --facts, --brief, --prd, --write-vision or --file."

# --- resolve the repo (the SAME resolution readiness.sh / the gate use) -----
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" || GIT_DIR=""
TOPLEVEL="$PWD"
FOUNDATION=""; FOUNDATION_WHY=""
if [ -n "$GIT_DIR" ]; then
  case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac
  TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || TOPLEVEL="$PWD"
  lcars_test_readiness "$GIT_DIR/lcars/config.json" >/dev/null 2>&1 || true
  FOUNDATION="${LCARS_TESTREADY_FOUNDATION:-}"
  FOUNDATION_WHY="${LCARS_TESTREADY_FOUNDATION_WHY:-}"
fi
MISSIONS_DIR="${GIT_DIR:+$GIT_DIR/lcars/missions}"

# ---------------------------------------------------------------------------
# THE FACTS — real detection, never a hardcoded string.
# ---------------------------------------------------------------------------
# The `untested` screen's FOUND panel is a REPORT, and a report that guesses is
# worse than no report: a captain pointing LCARS at real work reads this to
# decide whether LCARS understands his repo at all. So the stack comes from the
# SAME `detect_stack` init seeds config.json from, and the source-file count
# from the SAME extension/manifest evidence `lcars_repo_has_code` decides
# `greenfield` vs `untested` on (`_lcars_fnd_find` prunes node_modules, vendor,
# target, dist, build, .venv … so a `pnpm install` cannot inflate it).

# ev_js_label — the FRAMEWORK-level name for a `js` repo (fix round 1, D4).
#
# `detect_stack` answers `js`, which is true and uselessly coarse on the one
# panel whose entire job is to prove LCARS actually LOOKED at the captain's
# code: his measured case is a real React+Vite app and the panel told him
# "JavaScript / Node", i.e. nothing he did not already know. The classifier is
# NOT touched (it is the key every downstream arm is wired to); this reads the
# manifest the classifier already found and composes a LABEL from it.
#
# Positive evidence only, and jq-free: a dependency name in package.json, or
# tsconfig.json on disk. Nothing found ⇒ the honest coarse fallback.
ev_js_label() {
  local pkg="$TOPLEVEL/package.json" fw="" build="" ts=""
  [ -f "$pkg" ] || { printf 'JavaScript / Node'; return 0; }
  # The framework, most specific first — Next/Nuxt/Remix imply React/Vue, so
  # they win over the library they are built on rather than listing both.
  local f
  for f in next nuxt remix @remix-run/react @angular/core svelte vue react; do
    if grep -q "\"$f\"[[:space:]]*:" "$pkg" 2>/dev/null; then
      case "$f" in
        next)  fw="Next.js" ;;
        nuxt)  fw="Nuxt" ;;
        remix|@remix-run/react) fw="Remix" ;;
        @angular/core) fw="Angular" ;;
        svelte) fw="Svelte" ;;
        vue)   fw="Vue" ;;
        react) fw="React" ;;
      esac
      break
    fi
  done
  for f in vite webpack parcel rollup esbuild; do
    if grep -q "\"$f\"[[:space:]]*:" "$pkg" 2>/dev/null; then
      case "$f" in
        vite)    build="Vite" ;;
        webpack) build="Webpack" ;;
        parcel)  build="Parcel" ;;
        rollup)  build="Rollup" ;;
        esbuild) build="esbuild" ;;
      esac
      break
    fi
  done
  # TypeScript is a fact about the SOURCE, so either signal counts: the config
  # a compiler needs, or the dependency that installs it.
  if [ -f "$TOPLEVEL/tsconfig.json" ] \
     || grep -q '"typescript"[[:space:]]*:' "$pkg" 2>/dev/null; then
    ts="TypeScript"
  fi
  local head=""
  if [ -n "$fw" ] && [ -n "$build" ]; then head="$fw + $build"
  elif [ -n "$fw" ];    then head="$fw"
  elif [ -n "$build" ]; then head="$build"
  fi
  if [ -z "$head" ]; then
    [ -n "$ts" ] && { printf 'Node · TypeScript'; return 0; }
    printf 'JavaScript / Node'; return 0
  fi
  if [ -n "$ts" ]; then printf '%s · %s' "$head" "$ts"; else printf '%s' "$head"; fi
}

ev_stack_label() { # stack id → the human name (the classifier key is not a name)
  case "${1:-}" in
    js)      ev_js_label ;;
    python)  printf 'Python' ;;
    rust)    printf 'Rust' ;;
    go)      printf 'Go' ;;
    ruby)    printf 'Ruby' ;;
    dotnet)  printf '.NET' ;;
    jvm)     printf 'JVM (Java / Kotlin)' ;;
    unknown|'') printf 'not recognised' ;;
    ambiguous*) printf 'several (%s)' "${1#ambiguous(}" ;;
    *)       printf '%s' "$1" ;;
  esac
}

ev_source_files() { # → how many SOURCE files this repo actually holds
  _lcars_fnd_find "$TOPLEVEL" 6 -type f -print 2>/dev/null \
    | grep -vE '/\.git(/|$)' \
    | grep -cE "\.($LCARS_SOURCE_EXTS)\$|/($LCARS_MANIFEST_FILES)\$" \
    | tr -d ' '
}

ev_mission_count() { # → how many missions this repo has to put on a board
  local n=0 d
  [ -n "$MISSIONS_DIR" ] && [ -d "$MISSIONS_DIR" ] || { printf '0'; return 0; }
  for d in "$MISSIONS_DIR"/*/state.json; do [ -f "$d" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

# ev_front_door — 0 when the front door REPLACES the board. BOTH conditions, and
# the second one is the one that was measured missing: a locking verdict AND
# nothing to put on the board. See THE NARROW RULE in the header.
ev_front_door() {
  case "$FOUNDATION" in greenfield|untested) : ;; *) return 1 ;; esac
  [ "$(ev_mission_count)" = "0" ]
}

if [ "$MODE" = "facts" ]; then
  stack="$(detect_stack 2>/dev/null)" || stack="unknown"
  label="$(ev_stack_label "$stack")"
  n="$(ev_source_files)"; [ -n "$n" ] || n=0
  fd=false; ev_front_door && fd=true
  fnd='null'; [ -n "$FOUNDATION" ] && fnd="\"$(lcars_json_escape "$FOUNDATION")\""
  fwhy='null'; [ -n "$FOUNDATION_WHY" ] && fwhy="\"$(lcars_json_escape "$FOUNDATION_WHY")\""
  # testRunner is ALWAYS null here by construction: this payload is only ever
  # read on a repo whose verdict is greenfield/untested, and both of those mean
  # "no test system". It is present as a NAMED FACT because the screen states it
  # ("Test runner: none found") and a screen that states a fact must read it
  # from somewhere rather than assert it in markup.
  printf '{"foundation":%s,"foundationWhy":%s,"stack":"%s","stackLabel":"%s","sourceFiles":%s,"testRunner":null,"missions":%s,"frontDoor":%s}\n' \
    "$fnd" "$fwhy" "$(lcars_json_escape "$stack")" "$(lcars_json_escape "$label")" \
    "$n" "$(ev_mission_count)" "$fd"
  exit 0
fi

# ---------------------------------------------------------------------------
# THE FOUNDATION BRIEF — the scope fence in the grill's own words.
# ---------------------------------------------------------------------------
# This text is PREPENDED to the captain's idea and handed to the existing Align
# grill, so the interviewer that runs is the one LCARS already has (brief item
# 5) and the fence is the first thing it reads. It is also what the CLI prints,
# so the captain and the model are looking at the same contract.
ev_brief() {
  local seen=""
  if [ "$FOUNDATION" = "untested" ]; then
    local stack label n
    stack="$(detect_stack 2>/dev/null)" || stack="unknown"
    label="$(ev_stack_label "$stack")"
    n="$(ev_source_files)"
    seen="THIS REPO ALREADY HAS CODE — you can see it, so DO NOT ASK WHAT WE ARE
BUILDING. LCARS detected: $label, $n source files, and NO test runner. Ask only
what you cannot see: which runner suits this codebase, and what one existing
behaviour a first test should pin. The captain's code is NOT TOUCHED by this
mission — say so if he asks."
  else
    seen="THIS REPO IS EMPTY. Start by asking what we are building, in plain
language, and keep asking until you could name a stack and defend it."
  fi
  cat <<BRIEF
=== ESTABLISH VISION — THE FOUNDATION BRIEF (read this before anything else) ===

$seen

WHAT YOU ARE PRODUCING is ONE initialization mission whose entire scope is THE
FOUNDATION:

  1. a running SKELETON — the project boots and shows something;
  2. a working TEST SYSTEM — a real runner, wired, that a human can watch run;
  3. ONE THIN VERTICAL SLICE that proves both are genuinely connected.

That is the whole mission. You MUST NOT build the product. You must not plan
its features, its screens, its data model or its schedule. Every feature the
captain names is RECORDED and DEFERRED: it goes into the project vision doc and
becomes a normal LCARS mission once the foundation lands. A vision that
specifies twelve features has FAILED, not succeeded.

YOU RECOMMEND, YOU DO NOT DECIDE. End by recommending ONE stack — named
concretely, e.g. "Vite + React + Vitest" — with two to four reasons stated in
the CAPTAIN'S OWN LANGUAGE, referencing the thing he actually said he wants
rather than generic marketing copy. The choice is HIS: he may override the
recommendation with any stack he likes, and the stack he accepts is the one
that lands in the mission. Never present the recommendation as settled.

WHAT TO HAND BACK when you are done:
  stack     — the ONE recommended stack, as a short concrete name
  reasons   — 2–4 reasons, one per line, in his language
  slice     — the ONE thin vertical slice that proves skeleton + tests together,
              as a NOUN PHRASE that completes the sentence "One thin vertical
              slice that proves both: ______" — e.g. "importing a CSV row and
              showing it". NOT a full sentence, and no trailing full stop.
  deferred  — every feature he named, one per line, for the vision doc
BRIEF
}

if [ "$MODE" = "brief" ]; then ev_brief; exit 0; fi

# ---------------------------------------------------------------------------
# THE ARTEFACTS — the PRD, the vision doc, the mission.
# ---------------------------------------------------------------------------
[ -n "$IDEA_SRC" ] || die "no idea given — pass --idea <file>."
[ -f "$IDEA_SRC" ] || die "idea file not found: $IDEA_SRC"
[ -n "$STACK" ] || die "no stack given — pass --stack '<the stack the captain accepted>'."
IDEA="$(cat "$IDEA_SRC")"
REASONS=""; [ -n "$REASONS_SRC" ] && [ -f "$REASONS_SRC" ] && REASONS="$(cat "$REASONS_SRC")"
DEFERRED=""; [ -n "$DEFERRED_SRC" ] && [ -f "$DEFERRED_SRC" ] && DEFERRED="$(cat "$DEFERRED_SRC")"
# THE SLICE IS A NOUN PHRASE (fix round 1, D3) — the phrase that COMPLETES
# "One thin vertical slice that proves both: <slice>". A live model hands back a
# whole sentence about as often as a phrase, and the first live-shaped stub did
# exactly that, producing a label said twice and a doubled full stop on screen.
# Normalised HERE as well as in board.js, so the screen and the filed mission
# cannot say different things.
ev_norm_slice() { # prose-or-phrase → the phrase
  printf '%s' "$1" \
    | sed -E 's/^[^—:]*[Tt]hin( vertical)? slice[^—:]*[—:][[:space:]]*//' \
    | sed -E 's/^[^—:]*[Pp]roves? both[^—:]*[—:][[:space:]]*//' \
    | sed -E 's/[.[:space:]]+$//'
}
SLICE="$(ev_norm_slice "$SLICE")"
[ -n "$SLICE" ] || SLICE="the skeleton renders and the test system proves it"
[ -n "$TITLE" ] || TITLE="Establish the foundation — $STACK"

ev_bullets() { # text → "- line" per non-empty line; "" when there are none
  printf '%s\n' "$1" | while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in -\ *|\*\ *) printf '%s\n' "$l" ;; *) printf -- '- %s\n' "$l" ;; esac
  done
}

# ev_prd — THE FENCE, BY CONSTRUCTION. The grill fills in the STACK, the REASONS
# and the SLICE. It does not fill in the scope: Goal, Acceptance Criteria and
# Out of Scope are this template's, so no amount of enthusiasm in the interview
# can put "bank sync via Plaid" into an initialization mission. The captain's
# idea is quoted for context and is explicitly labelled as NOT the scope.
ev_prd() {
  # `Type` is `feature`, not `chore`: file.sh accepts only `feature` or `bug`
  # (checked at filing time), and of the two this is the honest one — the
  # foundation is something the repo did not have and now will. The fact that
  # this is an INITIALIZATION mission is carried by `missionType` in state.json,
  # which is what S185 keys off; the PRD's Type stays in the vocabulary every
  # other surface already speaks.
  cat <<PRD
# Mission: $TITLE

**Type:** feature

**Goal:** Establish the FOUNDATION of this project on $STACK — a running
skeleton, a working test system, and one thin vertical slice that proves the two
are genuinely connected. This mission does NOT build the product; it builds the
ground every later mission stands on, so that from here on every ticket can be
proven by running its tests.

**Acceptance Criteria:**
- The project SKELETON runs: a single documented command starts it and it shows
  something real.
- A TEST SYSTEM is installed and wired for $STACK: a single documented command
  runs the suite, and a human watching it can see it run.
- ONE THIN VERTICAL SLICE exists end to end — $SLICE — and it is covered by at
  least one REAL test that fails if the behaviour is removed.
- The test command is recorded so LCARS can run it (\`lcars update --test-command
  '<command>'\`), and \`lcars status\` reports the repo as ready.
- No feature from the project vision is implemented by this mission.

**Out of Scope:** EVERY product feature. This is the initialization mission and
its fence is deliberate: the features the captain described are recorded in the
project vision (\`.git/lcars/vision.md\`) and each becomes its own normal LCARS
mission once this foundation lands. Also out of scope: CI/CD pipelines,
deployment, authentication, persistence beyond what the one slice needs, and any
screen or data model that is not the slice above.

**Constraints:**
- The stack is the captain's accepted choice: **$STACK**. Do not substitute it.
- The test system must be a REAL runner that a human can watch execute — the
  captain is at Verify precisely to see the suite run.
- Existing code in this repo is not rewritten; the foundation is added alongside it.

## Context

The project's vision — what this is eventually FOR, and every feature the
captain named — is recorded at \`.git/lcars/vision.md\`. It is BACKGROUND ONLY.
Nothing in it is in scope for this mission, and it is deliberately not restated
here: a feature list quoted into an initialization mission is a feature list a
planner will try to satisfy. Read it for taste (naming, tone, rough shape); take
the scope from the sections above and nowhere else.
PRD
}

if [ "$MODE" = "prd" ]; then ev_prd; exit 0; fi

# --- the vision doc: durable, git-invisible, and read by later missions -----
# `.git/lcars/vision.md` — beside config.json and missions/, so the TARGET
# repo's working tree stays clean (CLAUDE.md) and nothing here is ever committed
# into the captain's project. This is where the DEFERRED features live: recorded
# in full, out of the initialization mission, and there for the missions that
# come after it.
[ -n "$GIT_DIR" ] || die "not inside a git repository — run this from a repo root."
VISION="$GIT_DIR/lcars/vision.md"
mkdir -p "$GIT_DIR/lcars"
{
  printf '# Project vision\n\n'
  printf '_Written by Establish Vision (`lcars` / the viewscreen front door). This\n'
  printf 'file is the durable record of what this project is FOR. The initialization\n'
  printf 'mission below builds only the foundation; everything under DEFERRED becomes\n'
  printf 'a normal LCARS mission once that foundation lands._\n\n'
  # S184 fix round 2, D8 — THE SECTION NEVER GOES OUT BLANK. The `untested`
  # door does not ask what we are building (it can SEE the code — screen 2
  # REPORTS instead of asking), so `--idea` legitimately arrives empty and this
  # heading was printed with nothing under it. In a durable record a blank
  # reads as "the captain said nothing", when the truth is that he was never
  # asked; so the doc says which of the two it is.
  printf '## What the captain asked for\n\n'
  if [ -n "$(printf '%s' "$IDEA" | tr -d '[:space:]')" ]; then
    printf '%s\n\n' "$IDEA"
  else
    printf 'Nothing was dictated here. This project was read from the code\n'
    printf 'already in the repo — LCARS found no test system and recommended\n'
    printf 'the foundation below from what it could see. The scope of the\n'
    printf 'initialization mission is that foundation; the existing code is\n'
    printf 'not touched.\n\n'
  fi
  printf '## Stack (accepted)\n\n**%s**\n\n' "$STACK"
  if [ -n "$REASONS" ]; then
    printf '### Why\n\n'; ev_bullets "$REASONS"; printf '\n'
  fi
  printf '## Foundation — the initialization mission\n\n'
  printf -- '- A running skeleton.\n'
  printf -- '- A working test system for %s.\n' "$STACK"
  printf -- '- One thin vertical slice: %s\n\n' "$SLICE"
  printf '## DEFERRED — features, recorded here, NOT in the initialization mission\n\n'
  if [ -n "$DEFERRED" ]; then
    ev_bullets "$DEFERRED"
  else
    printf -- '- (none recorded)\n'
  fi
  printf '\n_Each of these becomes its own `lcars file` mission once the foundation lands._\n'
} >"$VISION"

if [ "$MODE" = "vision" ]; then printf '%s\n' "$VISION"; exit 0; fi

# --- file the INITIALIZATION mission through the ONE sanctioned filer -------
# ADR-002: this script never mints a mission itself. `file.sh --initialization`
# is the same filer every other mission goes through — it simply carries the
# mission TYPE that lets it past the S183 gate (which exists to refuse NORMAL
# missions on exactly this repo) and stamps `missionType` for S185 to consume.
PRD_TMP="$GIT_DIR/lcars/tmp/vision-prd.$$.md"
mkdir -p "$(dirname "$PRD_TMP")"
ev_prd >"$PRD_TMP"
out=""; rc=0
out="$(bash "$FILE_SH" --initialization --prd "$PRD_TMP" 2>&1)"; rc=$?
rm -f "$PRD_TMP"
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || exit "$rc"
mid="$(printf '%s' "$out" | sed -n 's/.*Mission filed:[[:space:]]*\([A-Za-z0-9][A-Za-z0-9_-]*\).*/\1/p' | head -1)"
[ -n "$mid" ] || mid="$(ls -t "$MISSIONS_DIR" 2>/dev/null | head -1)"
printf 'MISSION_ID=%s\n' "$mid"
printf '\n◇ VISION RECORDED — %s\n' "$VISION"
exit 0
