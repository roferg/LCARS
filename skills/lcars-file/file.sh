#!/usr/bin/env bash
#
# lcars file — persist a new Mission and open its GitHub issue.
#
# This is the mechanical half of `lcars file`. The conversational half
# (Capture + Align) is driven by Claude per SKILL.md and produces a PRD on
# disk; this script takes that PRD and:
#   1. mints a mission ID            lcars-YYYYMMDD-NNN-<fp>  (NNN per-day
#                                    sequence; <fp> the 4-hex per-CLONE
#                                    fingerprint added in S196, so two laptops
#                                    filing on one day cannot mint one name for
#                                    one shared branch. Pre-S196 ids keep their
#                                    shape for ever — nothing is re-minted.)
#   2. creates .git/lcars/missions/<id>/ with prd.md + state.json
#   3. opens a GitHub issue labelled lcars:align + lcars:<type> + lcars:mission
#   4. prints a confirmation summary
#
# Type and title are read from the PRD itself (the `**Type:**` and
# `# Mission:` lines), so Claude only has to hand over a well-formed PRD.
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
# The lcars-run driver that owns the end-of-Align estimator (session 59). Default
# matches how SKILL.md invokes the other run.sh subcommands; overridable so tests
# can point it at a stub estimator driver. The estimator is OPTIONAL — see below.
RUN_BIN="${LCARS_RUN_BIN:-$HOME/.claude/skills/lcars-run/run.sh}"

die() { printf 'lcars file: %s\n' "$1" >&2; exit 1; }

# die_prd — THE SAME REFUSAL, WITH A DIFFERENT NUMBER ON IT.
#
# Every `die` above is an ENVIRONMENT fault: bad argv, no such mission, a path
# that does not exist, a repo that is not a repo. Retrying one of those with a
# freshly-written PRD cannot possibly help.
#
# `die_prd` is the other class: the ARTIFACT THE ALIGN WORKER JUST WROTE is
# wrong — a missing section, an unreadable Mission title or Type, a malformed
# ADR, or a design brief's open questions dropped on the floor. Those are the
# refusals a REDRAFT can actually clear, and the viewscreen's Align console
# heals them by handing this message back to the warm grill (see
# `_finalize_with_heal`, web/lcars_serve/actions.py) instead of dying on the
# captain — who did not write that PRD.
#
# The two classes are split HERE, at the exit status, and NOWHERE ELSE. A
# caller must never classify a refusal by matching its wording: S165's ruling is
# that the filter keys off EXIT STATUS, because the message is prose and prose
# drifts. The message text is unchanged; only the number it exits with is new.
#
#   exit 3 = "the PRD/ADR itself is wrong and a redraft could fix it"
#   exit 1 = everything else (unchanged)
#
# The GATES THEMSELVES ARE UNTOUCHED by this. Nothing here decides whether a PRD
# is acceptable — `lcars_prd_has_field` / `lcars_prd_questions_gate` still do,
# with exactly the judgement they had.
die_prd() { printf 'lcars file: %s\n' "$1" >&2; exit 3; }

# --- version check + ask-to-update (interactive; S129) ---------------------
# `lcars file` is an interactive entry point, so BEFORE any real work we run the
# throttled version check in ASK mode. Fully guarded (`|| true`) + honours the
# LCARS_VERSION_CHECK=0 kill switch, so it can never fail the filing.
FILE_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_CHECK="${LCARS_VERSION_CHECK_BIN:-$FILE_SKILL_DIR/../lcars-version/check.sh}"
[ -f "$VERSION_CHECK" ] && bash "$VERSION_CHECK" ask || true

# --- shared helpers: the base-freshness guard (S158) ------------------------
# `ensure_base_current` + its state-line writer live in the shared lib so that
# `lcars run`'s start-time re-check (S159) and the viewscreen's badge +
# File-console pre-flight (S160, via skills/lcars-init/base-freshness.sh)
# consume the SAME verdict machinery — one implementation, one vocabulary. All
# three are built; `lcars file`, `lcars run` and the board are its consumers.
# Sourcing is best-effort: if the lib is missing, filing degrades to exactly its
# pre-S158 behaviour rather than failing.
LCARS_COMMON_LIB="${LCARS_COMMON_LIB:-$FILE_SKILL_DIR/../lcars-init/lcars-common.sh}"
if [ -f "$LCARS_COMMON_LIB" ]; then
  # shellcheck source=../lcars-init/lcars-common.sh
  . "$LCARS_COMMON_LIB"
fi
# S237 — THE ANCHOR RULE, INTO THE PRD'S CONSTRAINTS, AT ALIGN.
# When one of the staged attachments is a MOCKUP, the PRD on disk carries the
# anchor rule with the drawing's ACTUAL element ids — the same list
# `validate_plan_json` checks a `drawnAt` against, from the same ONE source file
# the Plan prompt reads (lcars-run/stages/anchor-rule.md). No mockup ⇒ nothing
# at all, so every other mission's prd.md is byte-identical.
#
# WHY THE PRD AND NOT ONLY THE PROMPT. Over the weekend of 26–29 Sep a Plan
# Stage burned SIX attempts across TWO missions on this rule and then stopped
# dead, with the harness' own anchor prose and places list ALREADY in the Plan
# prompt. The cure that worked FIRST TIME was the captain pasting this line into
# Constraints — the register the planner reads as requirements. So it goes in
# both places, from one file. BEST-EFFORT by rule: a missing rule paragraph must
# never be the thing that fails a filing (same contract as the estimator).
_lcars_inject_anchor_rule() { # mission-dir  relpaths...
  local md="$1"; shift
  [ "$#" -gt 0 ] || return 0
  command -v lcars_anchor_rule_line >/dev/null 2>&1 || return 0
  local abs=() r
  for r in "$@"; do abs+=("$md/$r"); done
  local places; places="$(lcars_mockup_place_names "${abs[@]}")"
  # A mockup with no ids still gets the rule (the unfenced form); a mission with
  # no mockup at all gets nothing.
  if [ -z "$places" ]; then
    lcars_attach_has_mockup "${abs[@]}" || return 0
  fi
  local rule; rule="$(lcars_anchor_rule_line "$places" 2>/dev/null)" || return 0
  [ -n "$rule" ] || return 0
  lcars_prd_inject_constraint "$md/prd.md" "$rule"
}

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

if ! command -v ensure_base_current >/dev/null 2>&1; then
  ensure_base_current() {
    LCARS_BASE_VERDICT=""; LCARS_BASE_BEHIND=""; LCARS_BASE_AHEAD=""
    LCARS_BASE_SHA=""; LCARS_BASE_CHECKED_AT=""
    return 0
  }
  lcars_base_state_line() { printf ''; }
  lcars_base_branch_note() { printf ''; }
fi
# --- shared helpers: the ONE issue-body composer (S188) --------------------
# All four filing lanes below (park, --complete's edit, --complete's create, and
# grill-first --prd) compose their issue body through `lcars_issue_body_compose`
# so they cannot drift apart, and so every body carries the machine-readable
# `lcars:handoff` envelope a second laptop reads. It lives beside the host
# adapter in the sibling lcars-run skill dir — the same reach `lcars log` and
# `lcars feedback` already make for host-adapter.sh. $LCARS_ISSUE_BODY_LIB
# overrides the path for tests.
LCARS_ISSUE_BODY_LIB="${LCARS_ISSUE_BODY_LIB:-$FILE_SKILL_DIR/../lcars-run/issue-body.sh}"
if [ -f "$LCARS_ISSUE_BODY_LIB" ]; then
  # shellcheck source=../lcars-run/issue-body.sh
  . "$LCARS_ISSUE_BODY_LIB"
fi
if ! command -v lcars_issue_body_compose >/dev/null 2>&1; then
  die "the issue-body composer is missing ($LCARS_ISSUE_BODY_LIB) — re-run ./install.sh from the LCARS checkout."
fi

# --- shared helpers: solo ownership (S189) ---------------------------------
# The mission the captain files is HIS: filing assigns him on GitHub, which is
# where BOTH laptops read ownership from (the second laptop has no .git/lcars at
# all, so local state cannot answer "whose is this?"). Sourced from the sibling
# lcars-run skill dir — the same reach the issue-body composer above makes.
# $LCARS_OWNERSHIP_LIB overrides the path for tests.
#
# UNLIKE the composer, a MISSING library is NOT fatal here: ownership is a
# best-effort overlay on filing, never a precondition for it.
LCARS_OWNERSHIP_LIB="${LCARS_OWNERSHIP_LIB:-$FILE_SKILL_DIR/../lcars-run/ownership.sh}"
if [ -f "$LCARS_OWNERSHIP_LIB" ]; then
  # shellcheck source=../lcars-run/ownership.sh
  . "$LCARS_OWNERSHIP_LIB"
fi

# _claim_note <issue> — assign the new issue to the captain, BEST-EFFORT.
#
# A failed assign WARNS and returns 0. It must NEVER block filing: the same
# posture notify.sh and the comment mirror already have, and for the same reason
# — a forge that will not take an assignment is not a reason to lose the PRD the
# captain just wrote. The adapter's issue-assign READS BACK before reporting
# success, so a GitHub that accepts the request and silently drops it surfaces
# here as this warning, instead of as a mission LCARS believes it owns and
# GitHub says it does not.
_claim_note() { # <issue>
  local n="${1:-}" w
  case "$n" in ''|null) return 0 ;; esac
  command -v lcars_claim_mission >/dev/null 2>&1 || return 0
  w="$(lcars_claim_mission "$n")" || true
  [ -n "$w" ] && printf '%s\n' "$w"
  return 0
}

if ! command -v lcars_base_current_branch >/dev/null 2>&1; then
  # The lib is missing, so filing degrades to exactly its pre-S158 behaviour —
  # including the base resolution, which is the pre-S158 lines verbatim.
  lcars_base_current_branch() {
    local b; b="$("$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    case "$b" in ''|HEAD) b="main" ;; esac
    printf '%s' "$b"
  }
fi

# _append_branch_note — fold the mission-branch truth (S158 round 1, D6) into
# BRANCH_NOTE, the readout line that already reports what happened to
# `lcars/<id>`. Keeping them together is the point: "✓ filed against the CURRENT
# tree" printed directly above "⚠ branch already exists — reusing it" was two
# adjacent lines contradicting each other.
_append_branch_note() {
  local n; n="$(lcars_base_branch_note "$BRANCH" "$BASE" "${BRANCH_ORIGIN:-}")"
  [ -n "$n" ] || return 0
  if [ -n "${BRANCH_NOTE:-}" ]; then
    BRANCH_NOTE="$BRANCH_NOTE
$n"
  else
    BRANCH_NOTE="$n"
  fi
  return 0
}

# _print_note <note> — echo a branch/base note, restoring the blank line that
# closes the ⚠ MISSION BRANCH block. The block ends in a trailing newline that
# `$(…)` strips, so it butted straight against `Mission filed:` while the BASE
# FRESHNESS block (printed directly, not captured) kept its spacing — two blocks
# of the same weight looking different for no reason (round 2, promoted copy f).
_print_note() {
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$1"
  case "$1" in *'MISSION BRANCH'*) printf '\n' ;; esac
  return 0
}

# _branch_source_desc — what `lcars/<id>` was ACTUALLY cut from, for the readout's
# `(off …)`. Round 2, D3: the line printed `(off $BASE)` unconditionally, so a
# mission filed from a detached HEAD claimed to be off `main` when it was cut from
# a commit `main` does not even contain. `git branch <name>` takes its start point
# from HEAD, so HEAD is the answer — and a REUSED branch was not cut by this
# filing at all, so it gets its own honest wording.
#
# Round 4, D1 (cosmetic): in a repo with NO COMMITS nothing was cut from
# anything, and `$BASE` there is the literal-`main` fallback (`rev-parse
# --abbrev-ref HEAD` fails on an unborn HEAD) — so the readout printed
# `(off main)` two lines under "repo has no commits yet — branch … not created",
# naming a local branch that exists nowhere. `symbolic-ref --short HEAD` answers
# on an unborn HEAD, so name the branch the captain is really on and say it has
# no commits yet.
_branch_source_desc() {
  local hb sha
  if ! "$GIT_BIN" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    hb="$("$GIT_BIN" symbolic-ref -q --short HEAD 2>/dev/null)" || hb=""
    [ -n "$hb" ] && { printf '%s — no commits yet' "$hb"; return 0; }
  fi
  case "${BRANCH_ORIGIN:-}" in
    reused)
      sha="$("$GIT_BIN" rev-parse --short "refs/heads/$BRANCH" 2>/dev/null)"
      [ -n "$sha" ] && { printf 'existing branch at %s' "$sha"; return 0; }
      ;;
    new)
      hb="$("$GIT_BIN" symbolic-ref -q --short HEAD 2>/dev/null)" || hb=""
      [ -n "$hb" ] && { printf '%s' "$hb"; return 0; }
      sha="$("$GIT_BIN" rev-parse --short HEAD 2>/dev/null)"
      [ -n "$sha" ] && { printf 'detached HEAD %s' "$sha"; return 0; }
      ;;
  esac
  printf '%s' "$BASE"
}

# --- THE FOUNDATION GATE (S183) --------------------------------------------
# A normal mission cannot be filed against a repo with no test foundation. The
# decision, the verdict and the wording ALL live in ONE seam —
# skills/lcars-init/foundation-gate.sh — which SESSION 184 replaces with the
# real Establish Vision flow; nothing about the refusal is duplicated here.
#
# It runs BEFORE any worker is hired (`lcars file`'s only paid step is the
# end-of-Align estimator, dispatched much further down) and before anything at
# all is written, so a refused filing leaves the repo untouched.
#
# ALLOWED, deliberately: `unconfigured` — a repo that HAS a test system LCARS
# simply has no command for. That is the `lcars update --test-command` case and
# it keeps working exactly as it did. The gate DEGRADES TO ALLOW whenever it
# cannot get a verdict (helper missing, not an LCARS repo): it refuses only on a
# positive greenfield/untested, never on an absence of information.
#
# The refusal exits 4 — its own number, NOT `die`'s 1 and NOT `die_prd`'s 3. A
# redraft cannot clear it (so it is not 3), and the viewscreen's Align console
# keys its heal off exit status (S165) — healing a foundation refusal by
# re-grilling the PRD would loop forever.
FOUNDATION_GATE="${LCARS_FOUNDATION_GATE_BIN:-$FILE_SKILL_DIR/../lcars-init/foundation-gate.sh}"
_foundation_gate() {
  # S184 — the INITIALIZATION mission is the ONE exemption, and it is the point
  # of the exemption that it is narrow: this is the mission that ESTABLISHES the
  # foundation, filed by Establish Vision, so gating it on the foundation
  # existing would make the gate unsatisfiable. Every other filing on this repo
  # — grill-first, --park, a hotkey, the board — still hits the wall.
  [ "${INITIALIZATION:-0}" = "1" ] && return 0
  [ -f "$FOUNDATION_GATE" ] || return 0
  local out rc
  out="$(bash "$FOUNDATION_GATE" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 20 ] || return 0
  printf '%s\n' "$out" >&2
  exit 4
}

# ==========================================================================
# Park & Align helpers (S136). Defined here so the --park / --complete dispatch
# below can call them. None runs at source time.
# ==========================================================================

# Tiny jq-free JSON readers over a state.json file (same style as status.sh).
_fj_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
_fj_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }

# _lcars_dirs — resolve GIT_DIR / LCARS_DIR / MISSIONS_DIR / CONFIG (mirrors the
# grill-first inline resolution). Ensures missions/ exists.
_lcars_dirs() {
  GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac
  LCARS_DIR="$GIT_DIR/lcars"
  MISSIONS_DIR="$LCARS_DIR/missions"
  CONFIG="$LCARS_DIR/config.json"
  mkdir -p "$MISSIONS_DIR"
}

# _resolve_model — config.json wins, else $LCARS_MODEL, else claude-sonnet
# (identical resolution to grill-first). Echoes the model string.
_resolve_model() {
  local m=""
  [ -f "$CONFIG" ] && m="$(sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)"
  [ -n "$m" ] || m="${LCARS_MODEL:-claude-sonnet}"
  printf '%s' "$m"
}

# --- the engine pin: ONE validation + ONE precedence, shared by BOTH lanes ----
# `--engine claude|copilot` is the captain's EXPLICIT engine choice; it is the
# strongest signal there is, so it must beat the daemon-threaded
# $LCARS_WORKER_BIN, and a value that is neither engine must stop the filing
# before anything is written. Both lanes (grill-first --prd AND --park/--complete)
# call these two helpers — factored so the lanes cannot drift apart again, which
# is exactly how --engine came to be silently ignored on the --prd lane (a
# mission the captain pinned to copilot then billed real spend on claude).

# _validate_engine — die unless $ENGINE is empty or a known engine. Call this
# BEFORE any write so a bogus engine leaves nothing partial behind.
_validate_engine() {
  [ -n "$ENGINE" ] || return 0
  case "$ENGINE" in
    claude|copilot) return 0 ;;
    *) die "unknown engine '$ENGINE' — use 'claude' or 'copilot'." ;;
  esac
}

# _resolve_worker_bin [fallback] — echo the engine to persist as state.json's
# `workerBin`, in ONE precedence order used by ALL THREE lanes:
#     --engine  >  $LCARS_WORKER_BIN  >  <fallback>  >  nothing
# Empty result ⇒ the caller writes NO key, so host-detect stays in charge and a
# no-engine state.json is byte-identical to before.
#
# The optional fallback is what --complete carries forward from the PARKED
# mission's state.json. It sits BELOW both explicit signals on purpose: the
# viewscreen lets a captain pick an engine at START ALIGNMENT and runs the GRILL
# on it, then threads that pick to `file.sh --complete` as $LCARS_WORKER_BIN. If
# the parked value won, the grill and the pipeline would run on DIFFERENT
# engines — the one thing the engines-separate-paths rule forbids — and the
# captain's most recent, most explicit choice would be silently dropped.
#
# S222 — AND WHAT IT PERSISTS IS A PATH, NOT A NAME. The winner of that
# precedence used to be written into state.json verbatim, so a mission filed
# with `copilot` recorded the bare word and every later subprocess resolved it
# through PATH. On a machine with the VS Code Copilot extension that lookup is
# the fork-bomb shim, worker-guard.sh refuses it, and the captain sees his
# mission fail ("⚠ estimator unavailable", no cost pill, no difficulty pills)
# rather than his machine being saved. The precedence above is untouched; only
# the RECORDING is — an engine that would resolve to the shim is written as the
# real CLI's absolute path instead. Everything else is passed through byte for
# byte, so a mission that never had this problem has a byte-identical
# state.json. The shared rule, and why an OPERATOR-typed engine is deliberately
# NOT normalised, are in skills/lcars-init/worker-guard.sh.
_resolve_worker_bin() { # [fallback]
  local wb=""
  if   [ -n "$ENGINE" ];                 then wb="$ENGINE"
  elif [ -n "${LCARS_WORKER_BIN:-}" ];   then wb="$LCARS_WORKER_BIN"
  else                                        wb="${1:-}"
  fi
  if [ -n "$wb" ] && command -v lcars_worker_bin_prefer_real >/dev/null 2>&1; then
    lcars_worker_bin_prefer_real "$wb"
  else
    printf '%s' "$wb"
  fi
}

# _worker_bin_line <worker-bin> — the optional state.json line for `workerBin`,
# JSON-escaped so an odd engine string can never break the JSON. Empty input ⇒
# empty output ⇒ no key at all.
_worker_bin_line() {
  local wb="$1"
  [ -n "$wb" ] || { printf ''; return 0; }
  local wb_json="${wb//\\/\\\\}"; wb_json="${wb_json//\"/\\\"}"
  printf '  "workerBin": "%s",' "$wb_json"
}

# _mint_id — the per-day sequenced, CLONE-FINGERPRINTED mission id under
# $MISSIONS_DIR. Echoes it.
#
# S196 — the scan and the format both moved to lcars_mint_mission_id in
# lcars-common.sh, so this lane, the --prd lane below, and `lcars log` share ONE
# parser. Why the id widened at all (two laptops minting the same name for the
# same shared branch), and why the scan can no longer read `${d##*-}`, is
# written out in full over that function.
_mint_id() {
  lcars_mint_mission_id "$MISSIONS_DIR" "$DATE" "$(lcars_clone_fingerprint "$CONFIG")"
}

# _make_branch <id> — create the Mission's own branch lcars/<id> off the current
# branch (best-effort, mirrors grill-first). Sets BRANCH / BASE / BRANCH_NOTE.
_make_branch() {
  BRANCH="lcars/$1"
  # S160 — resolved through the SHARED helper, not a local copy of the same three
  # lines: the board's pre-flight check reports on the base a filing WOULD use,
  # and if the two resolutions could drift the console would confidently describe
  # the freshness of a branch the captain is not filing against.
  BASE="$(lcars_base_current_branch)"
  # S158 — bring BASE up to date BEFORE the branch is cut, so lcars/<id> starts
  # from the tree the rest of the world sees rather than a stale local ref. Never
  # blocks, never touches a dirty tree, and prints its own reason when it refuses.
  # BASEFRESH_LINE (the state.json record) is set below, once the branch exists —
  # identical to the grill-first lane.
  ensure_base_current "$BASE"
  BRANCH_NOTE=""
  BRANCH_ORIGIN=""   # reused | new | "" (none created) — round 2, D3
  if "$GIT_BIN" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    if "$GIT_BIN" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      BRANCH_NOTE="  ⚠ branch $BRANCH already exists — reusing it."
      BRANCH_ORIGIN="reused"
    elif ! "$GIT_BIN" branch "$BRANCH" >/dev/null 2>&1; then
      BRANCH_NOTE="  ⚠ could not create branch $BRANCH — create it before Implement."
    else
      BRANCH_ORIGIN="new"
    fi
  else
    BRANCH_NOTE="  ⚠ repo has no commits yet — branch $BRANCH not created; Implement will create it on first commit."
  fi
  BRANCH_SOURCE="$(_branch_source_desc)"
  # The state line and the mission-branch truth are both decided AFTER the branch
  # exists — they are claims about THIS mission, not about the base (D6).
  _append_branch_note
  BASEFRESH_LINE="$(lcars_base_state_line "$BRANCH")"
}

# _validate_prd <prd-path> — every required section present (same gates as
# grill-first, :121+). Dies on the first missing one, writing NOTHING.
_validate_prd() { # prd-path [attachment-path…]
  local p="$1"
  # S176 — BOTH shapes: the bold inline label AND the markdown-heading form the
  # captain's Align drifted to. lcars_prd_has_field (lcars-init/lcars-common.sh)
  # is the SAME function the title/type extraction below reads through, so
  # validation and extraction can never disagree about what a PRD says.
  lcars_prd_has_field "$p" 'Mission'             || die_prd "PRD is missing the 'Mission title' section — Align must produce it before filing."
  lcars_prd_has_field "$p" 'Type'                || die_prd "PRD is missing the 'Type' section — Align must produce it before filing."
  lcars_prd_has_field "$p" 'Goal'                || die_prd "PRD is missing the 'Goal' section — Align must produce it before filing."
  lcars_prd_has_field "$p" 'Acceptance Criteria' || die_prd "PRD is missing the 'Acceptance Criteria' section — Align must produce it before filing."
  lcars_prd_has_field "$p" 'Out of Scope'        || die_prd "PRD is missing the 'Out of Scope' section — Align must produce it before filing."
  lcars_prd_has_field "$p" 'Constraints'         || die_prd "PRD is missing the 'Constraints' section — Align must produce it before filing."
  # S175 — the design brief's OWN open questions must not evaporate here. Every
  # bullet under the concept doc's `## Open questions` is carried forward as a
  # question (still open, or resolved with the captain and recorded as resolved),
  # never quietly turned into an assertion. A no-op for every mission with no
  # concept doc, and for one whose brief left nothing open. See
  # lcars_prd_questions_gate in lcars-init/lcars-common.sh for the measurement.
  local qmsg
  if ! qmsg="$(lcars_prd_questions_gate "$p" "${@:2}" 2>&1)"; then
    die_prd "$qmsg"
  fi
}

# _validate_adr <adr-path> — shape-check (same gates as grill-first).
_validate_adr() {
  local a="$1"
  grep -q '\*\*Context:\*\*'                  "$a" || die_prd "ADR is missing the 'Context' section — each ADR needs Context / Decision / Alternatives considered / Consequences."
  grep -q '\*\*Decision:\*\*'                 "$a" || die_prd "ADR is missing the 'Decision' section — each ADR needs Context / Decision / Alternatives considered / Consequences."
  grep -q '\*\*Alternatives considered:\*\*'  "$a" || die_prd "ADR is missing the 'Alternatives considered' section — each ADR needs Context / Decision / Alternatives considered / Consequences."
  grep -q '\*\*Consequences:\*\*'             "$a" || die_prd "ADR is missing the 'Consequences' section — each ADR needs Context / Decision / Alternatives considered / Consequences."
}

# --------------------------------------------------------------------------
# do_park — file a mission from just the idea (no grill, no PRD, no estimate).
# --------------------------------------------------------------------------
do_park() {
  # S183 — the park lane is the OTHER way a normal mission is filed (the board's
  # ◇ File to Backlog), so it carries the same gate. `--complete` deliberately
  # does NOT: it finishes a mission that was already accepted and grilled.
  _foundation_gate
  # Resolve the idea text: --idea <file> wins, else the positional text.
  local idea=""
  if [ -n "$IDEA_SRC" ]; then
    [ -f "$IDEA_SRC" ] || die "idea file not found: $IDEA_SRC"
    idea="$(cat "$IDEA_SRC")"
  elif [ "${#POSITIONAL[@]}" -gt 0 ]; then
    idea="${POSITIONAL[*]}"
  fi
  [ -n "$idea" ] || die "no idea given — pass the idea text (or --idea <file>) to park a mission."

  # Optional engine → the parked mission's workerBin. Validate BEFORE any write
  # so a bogus engine stops parking with nothing partial (engines-separate-paths).
  _validate_engine

  # Attachments (S92) — each must exist, checked BEFORE anything is written.
  if [ "${#ATTACHMENTS[@]}" -gt 0 ]; then
    local a
    for a in "${ATTACHMENTS[@]}"; do
      [ -n "$a" ] || die "empty --attach path given."
      [ -f "$a" ] || die "attachment file not found: $a"
    done
  fi

  _lcars_dirs
  local ID; ID="$(_mint_id)"
  local MISSION_DIR="$MISSIONS_DIR/$ID"
  mkdir -p "$MISSION_DIR"

  _make_branch "$ID"

  # idea.md — the verbatim capture (the whole point of the fast lane).
  printf '%s\n' "$idea" >"$MISSION_DIR/idea.md"

  # Stage durable attachments exactly as S92 (into attachments/attachment-NN.ext),
  # collecting the relative paths for state.json. No prd.md exists yet, so — unlike
  # grill-first — there is no attachments section to append here; the --complete
  # step re-lists them into prd.md when the PRD is written.
  local ATTACH_RELS=()
  if [ "${#ATTACHMENTS[@]}" -gt 0 ]; then
    mkdir -p "$MISSION_DIR/attachments"
    local an=0 asrc aext arel
    for asrc in "${ATTACHMENTS[@]}"; do
      an=$((an + 1)); aext=""
      case "$asrc" in *.*) aext=".${asrc##*.}" ;; esac
      arel="$(printf 'attachments/attachment-%02d%s' "$an" "$aext")"
      cp "$asrc" "$MISSION_DIR/$arel"
      ATTACH_RELS+=("$arel")
    done
  fi

  local MODEL; MODEL="$(_resolve_model)"

  # workerBin: --engine wins, else the daemon-threaded $LCARS_WORKER_BIN, else none.
  local WB; WB="$(_resolve_worker_bin)"
  local WORKER_BIN_LINE; WORKER_BIN_LINE="$(_worker_bin_line "$WB")"

  local ATTACH_LINE=""
  if [ "${#ATTACH_RELS[@]}" -gt 0 ]; then
    local attach_items="" arel
    for arel in "${ATTACH_RELS[@]}"; do
      [ -n "$attach_items" ] && attach_items="$attach_items, "
      attach_items="$attach_items\"$arel\""
    done
    ATTACH_LINE="  \"attachments\": [$attach_items],"
  fi

  # The issue title = the first idea line, hard-truncated to ~70 chars.
  local first_line title_json
  first_line="$(printf '%s' "$idea" | head -1)"
  local PTITLE="${first_line:0:70}"
  title_json="${PTITLE//\\/\\\\}"; title_json="${title_json//\"/\\\"}"

  # write_park_state <issue-or-null> — a parked state.json: stage align +
  # "prdPending": true (the pre-PRD marker). No `type` (unknown until the grill).
  write_park_state() {
    {
      printf '{\n'
      printf '  "id": "%s",\n' "$ID"
      printf '  "title": "%s",\n' "$title_json"
      printf '  "stage": "align",\n'
      printf '  "prdPending": true,\n'
      printf '  "created": "%s",\n' "$NOW"
      printf '  "model": "%s",\n' "$MODEL"
      [ -n "$WORKER_BIN_LINE" ] && printf '%s\n' "$WORKER_BIN_LINE"
      [ -n "$ATTACH_LINE" ] && printf '%s\n' "$ATTACH_LINE"
      [ -n "${BASEFRESH_LINE:-}" ] && printf '%s\n' "$BASEFRESH_LINE"
      printf '  "githubIssue": %s,\n' "${1:-null}"
      printf '  "branch": "%s",\n' "$BRANCH"
      printf '  "base": "%s"\n' "$BASE"
      printf '}\n'
    } >"$MISSION_DIR/state.json"
  }
  write_park_state null

  # Open the GitHub issue — labels lcars:align + lcars:mission ONLY (NO type
  # label; type is unknown until the grill). Body = the idea + a standby note.
  local ISSUE="" GH_NOTE=""
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    # LANE 1 (park). ONE composer, shared with every other lane — see
    # skills/lcars-run/issue-body.sh. Byte-identical to the inline body this lane
    # built before S188, plus the appended `lcars:handoff` envelope (which
    # carries "parked":true here: there is no PRD yet).
    local BODY_TMP; BODY_TMP="$(mktemp "$MISSION_DIR/.issue-body.XXXXXX")"
    lcars_issue_body_compose "$MISSION_DIR" park >"$BODY_TMP"
    local url
    url="$("$GH_BIN" issue create \
            --title "$PTITLE" \
            --body-file "$BODY_TMP" \
            --label "lcars:align,lcars:mission" 2>/dev/null)"
    local num="${url##*/}"
    case "$num" in
      ''|*[!0-9]*) GH_NOTE="  ⚠ gh issue create failed — mission parked locally; re-run after fixing gh." ;;
      # Remember the body that actually reached GitHub. S188 fix round 2: this
      # lane was the ONE lane that never did, so a parked mission had no
      # carry-forward source at all — and a later refresh whose estimate.json or
      # adr.md had gone missing was left composing blind on the one lane most
      # likely to have a half-built mission dir. Same call, same place, as the
      # --complete and grill-first lanes.
      *) ISSUE="$num"; lcars_issue_body_record "$MISSION_DIR" "$BODY_TMP" ;;
    esac
    rm -f "$BODY_TMP"
  else
    GH_NOTE="  ⚠ gh CLI not found — mission parked locally without a GitHub issue."
  fi
  write_park_state "${ISSUE:-null}"

  # S189: a parked mission is still the captain's — claim it now, so a laptop
  # that adopts it later sees an owner rather than an orphan.
  _claim_note "${ISSUE:-}"

  local issue_line="(none — parked locally only)"
  [ -n "$ISSUE" ] && issue_line="#$ISSUE"
  [ -n "$GH_NOTE" ] && echo "$GH_NOTE"
  _print_note "${BRANCH_NOTE:-}"
  echo "  Mission parked: $ID"
  echo "  GitHub issue:   $issue_line"
  echo "  Branch:         $BRANCH (off ${BRANCH_SOURCE:-$BASE})"
  echo "  Stage:          align  ◇ STANDBY — awaiting alignment"
  echo "  Next:           run \`lcars file $ID\` to align it (the Align grill), then it flows the pipeline"
  return 0
}

# --------------------------------------------------------------------------
# do_complete — the grill-completion verb for a parked mission. Validates the
# PRD (same gates), writes prd.md, derives type/title, clears prdPending, runs
# the estimator, and updates the issue IN PLACE — landing byte-equivalent to a
# grill-first filing (the only extra artifact is idea.md).
# --------------------------------------------------------------------------
do_complete() {
  local ID="$COMPLETE_ID"
  [ -n "$ID" ] || die "no mission id — usage: lcars file --complete <id> --prd <path>."
  [ -n "$PRD_SRC" ] || die "no PRD given — pass --prd <path> to complete the alignment."
  [ -f "$PRD_SRC" ] || die "PRD file not found: $PRD_SRC"

  # The SAME engine gate the other two lanes run, BEFORE any write, so a bogus
  # engine leaves the mission parked with nothing partial (S147 round-2 D3 — this
  # lane was skipping it entirely and exiting 0 on a bogus engine).
  _validate_engine

  # Validate the model override up front (same rules as grill-first) so a bad
  # value stops BEFORE anything is written.
  local OV_SCOPE="" OV_TIER=""
  if [ -n "$MODEL_OVERRIDE" ]; then
    case "$MODEL_OVERRIDE" in
      *:*) : ;;
      *) die "malformed --model-override '$MODEL_OVERRIDE' — expected <scope>:<tier> (e.g. all:opus)." ;;
    esac
    OV_SCOPE="${MODEL_OVERRIDE%%:*}"; OV_TIER="${MODEL_OVERRIDE#*:}"
    case "$OV_SCOPE" in all|reasoning|implementation) : ;; *) die "invalid --model-override scope '$OV_SCOPE' — must be one of: all, reasoning, implementation." ;; esac
    case "$OV_TIER" in sonnet|opus) : ;; *) die "invalid --model-override tier '$OV_TIER' — must be one of: sonnet, opus." ;; esac
  fi

  _lcars_dirs
  local MISSION_DIR="$MISSIONS_DIR/$ID"
  local STATE="$MISSION_DIR/state.json"
  [ -d "$MISSION_DIR" ] || die "no mission '$ID' under .git/lcars/missions/ — check the id (or park one with \`lcars file --park\`)."
  [ -f "$STATE" ]       || die "mission '$ID' has no state.json — its state is corrupt."

  # Only a PARKED mission can be completed. A non-parked mission is already
  # aligned — say so cleanly (the resume path's clean message).
  local pend; pend="$(_fj_raw "$STATE" prdPending)"
  [ "$pend" = "true" ] || die "mission '$ID' is already aligned — nothing to complete (run \`lcars run $ID\` to advance it)."

  # Validate the PRD (and ADR when given) BEFORE any write — a bad PRD leaves the
  # mission untouched: no prd.md, prdPending still true (nothing partial).
  # S176 — the S175 open-questions gate needs the mission's DESIGN BRIEF to
  # measure the PRD against, and this call passed NONE: `_validate_prd` forwards
  # `"${@:2}"` to lcars_prd_questions_gate, so with no attachments the gate saw
  # no brief, found no open questions, and returned 0 for EVERY PRD — the gate
  # was silently disabled on the whole park→grill→--complete lane (the one the
  # holodeck hand-off uses). MEASURED: the captain's real PRD returned clean
  # here, and refused correctly — naming 12 dropped questions — the moment the
  # staged brief was handed over. On THIS lane the brief is MISSION-RELATIVE:
  # park already copied it into attachments/, so the source path is long gone.
  local QATTACH=()
  if [ -d "$MISSION_DIR/attachments" ]; then
    shopt -s nullglob
    local qa
    for qa in "$MISSION_DIR/attachments"/attachment-*; do QATTACH+=("$qa"); done
    shopt -u nullglob
  fi
  if [ "${#QATTACH[@]}" -gt 0 ]; then
    _validate_prd "$PRD_SRC" "${QATTACH[@]}"
  else
    _validate_prd "$PRD_SRC"
  fi
  if [ -n "$ADR_SRC" ]; then
    [ -f "$ADR_SRC" ] || die "ADR file not found: $ADR_SRC"
    _validate_adr "$ADR_SRC"
  fi

  # Derive title + type from the PRD (source of truth), same as grill-first.
  local TITLE TYPE
  TITLE="$(lcars_prd_field "$PRD_SRC" 'Mission' | head -1)"
  [ -n "$TITLE" ] || die_prd "could not read the Mission title from the PRD."
  TYPE="$(lcars_prd_field "$PRD_SRC" 'Type' | head -1 | tr 'A-Z' 'a-z' | tr -cd 'a-z')"
  case "$TYPE" in feature|bug) : ;; *) die_prd "PRD Type must be 'feature' or 'bug' (got: '${TYPE:-empty}')." ;; esac

  # Preserve the parked mission's durable fields so the final state.json is
  # byte-equivalent to a grill-first filing of the same PRD.
  local CREATED MODEL BRANCH BASE WB ISSUE
  CREATED="$(_fj_str "$STATE" created)"
  MODEL="$(_fj_str "$STATE" model)"
  BRANCH="$(_fj_str "$STATE" branch)"
  BASE="$(_fj_str "$STATE" base)"
  # The engine: an explicit --engine or a daemon-threaded $LCARS_WORKER_BIN (the
  # viewscreen's START ALIGNMENT picker) WINS over the parked value, which is the
  # fallback. Same helper, same order, as the park and grill-first lanes — so the
  # engine the grill just ran on is the engine the pipeline gets.
  WB="$(_resolve_worker_bin "$(_fj_str "$STATE" workerBin)")"
  ISSUE="$(_fj_raw "$STATE" githubIssue)"; case "$ISSUE" in null) ISSUE="" ;; esac
  # The base-freshness record is RE-DECIDED here (S158 round 1, D3). Park exists
  # precisely so an idea can sit in the backlog while origin moves on, so carrying
  # the park-time verdict forward means a mission asserting `"verdict": "updated"`
  # — whose own copy reads "filed against the CURRENT tree" — at the exact moment
  # the pipeline starts against a base that is behind. An expired claim is worse
  # than no claim. The mission BRANCH was cut at park time and is NOT re-cut or
  # moved; if it now lags the freshened base, lcars_base_branch_note says so out
  # loud with the command that fixes it.
  local BASEFRESH_LINE BRANCH_LAG
  ensure_base_current "$BASE"
  # The branch was cut at PARK time, so it pre-exists this run — say that,
  # never "cut from HEAD" (round 2, D3).
  BRANCH_LAG="$(lcars_base_branch_note "$BRANCH" "$BASE" reused)"
  BASEFRESH_LINE="$(lcars_base_state_line "$BRANCH")"

  # Reconstruct the staged attachments (S92) from the attachments/ dir, in order,
  # so prd.md gets the same attachments section a grill-first --attach filing
  # produces AND state.json carries the same array.
  local ATTACH_RELS=()
  if [ -d "$MISSION_DIR/attachments" ]; then
    shopt -s nullglob
    local f
    for f in "$MISSION_DIR/attachments"/attachment-*; do
      ATTACH_RELS+=("attachments/$(basename "$f")")
    done
    shopt -u nullglob
  fi

  # --- write prd.md (+ the attachments section, mirroring grill-first) --------
  cat "$PRD_SRC" >"$MISSION_DIR/prd.md"
  if [ "${#ATTACH_RELS[@]}" -gt 0 ]; then
    # ONE rule, shared with the grill-first lane and with `lcars log` and the
    # cold-Stage prompt block — see lcars_attach_prd_section in lcars-common.sh.
    lcars_attach_prd_section "${ATTACH_RELS[@]}" >>"$MISSION_DIR/prd.md"
    _lcars_inject_anchor_rule "$MISSION_DIR" "${ATTACH_RELS[@]}"
  fi
  # adr.md (complex mission) — persisted the same way grill-first does.
  [ -n "$ADR_SRC" ] && cat "$ADR_SRC" >"$MISSION_DIR/adr.md"

  # --- run the end-of-Align estimator (same timing contract: before the issue
  # body render) -------------------------------------------------------------
  local EST_NOTE=""
  if [ -f "$RUN_BIN" ]; then
    if bash "$RUN_BIN" estimate --mission "$ID" >/dev/null 2>&1 \
         && [ -f "$MISSION_DIR/estimate.json" ]; then
      :
    else
      EST_NOTE="  ⚠ estimator unavailable — mission aligned with default per-stage models."
    fi
  else
    EST_NOTE="  ⚠ estimator driver not found ($RUN_BIN) — mission aligned with default per-stage models."
  fi
  local EST_ISSUE=""
  if [ -f "$RUN_BIN" ] && [ -f "$MISSION_DIR/estimate.json" ]; then
    EST_ISSUE="$(bash "$RUN_BIN" render-estimate --mission "$ID" --surface issue 2>/dev/null)"
  fi

  # --- compose the issue body: prd → adr → Estimate (exactly grill-first) -----
  # LANE 2/3. ONE composer (skills/lcars-run/issue-body.sh), byte-identical to
  # the inline body this lane built before S188 plus the appended envelope.
  #
  # The envelope's `type` and `engine` are OVERRIDDEN here on purpose: this lane
  # composes BEFORE it clears `prdPending`, so state.json is still in its PARKED
  # shape — no `type` at all, and a `workerBin` that the re-resolution above may
  # have just superseded (--engine / the daemon-threaded $LCARS_WORKER_BIN beat
  # the parked value). Reading state.json here would ship a stale envelope on the
  # one lane whose state.json is deliberately not final yet.
  local BODY_TMP; BODY_TMP="$(mktemp "$MISSION_DIR/.issue-body.XXXXXX")"
  lcars_issue_body_compose "$MISSION_DIR" align "$EST_ISSUE" \
    "type=$TYPE" "engine=$WB" >"$BODY_TMP"
  local BODY_FILE="$BODY_TMP"

  # --- update the issue IN PLACE (retitle, re-body, add the type label) -------
  # prdPending is cleared LAST (below), so if this fails the mission stays parked
  # and a re-run retries the issue update — idempotent.
  local GH_NOTE="" GH_FAILED=0
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    if [ -n "$ISSUE" ]; then
      if "$GH_BIN" issue edit "$ISSUE" \
        --title "$TITLE" \
        --body-file "$BODY_FILE" \
        --add-label "lcars:$TYPE" >/dev/null 2>&1; then
        # Remember the body that actually reached GitHub: it is the baseline the
        # S188 regression guard measures the next recompose against, so a later
        # transfer point cannot silently delete a section off this issue.
        lcars_issue_body_record "$MISSION_DIR" "$BODY_FILE"
      else
        GH_FAILED=1; GH_NOTE="  ⚠ gh issue edit failed — mission left PARKED (NOT aligned). Re-run \`lcars file --complete $ID --prd <path>\` after fixing gh."
      fi
    else
      # No issue was opened at park time (gh was down) — create it now, grill-first
      # style (all three labels).
      local url num
      url="$("$GH_BIN" issue create --title "$TITLE" --body-file "$BODY_FILE" \
              --label "lcars:align,lcars:$TYPE,lcars:mission" 2>/dev/null)"
      num="${url##*/}"
      case "$num" in
        ''|*[!0-9]*) GH_FAILED=1; GH_NOTE="  ⚠ gh issue create failed — mission left PARKED (NOT aligned). Re-run \`lcars file --complete $ID --prd <path>\` after fixing gh." ;;
        *) ISSUE="$num"; lcars_issue_body_record "$MISSION_DIR" "$BODY_FILE" ;;
      esac
    fi
  else
    GH_NOTE="  ⚠ gh CLI not found — align recorded locally without updating a GitHub issue."
  fi
  [ -n "$BODY_TMP" ] && rm -f "$BODY_TMP"

  # --- DEFECT-1 guard: a gh issue UPDATE failure leaves the mission PARKED -----
  # We have NOT written the final (prdPending-cleared) state.json yet, so state
  # is still in its parked shape — "prdPending": true, no `type` — and the mission
  # stays runnable-blocked. Bail out NON-ZERO with the re-run instruction rather
  # than clearing prdPending: otherwise local state would read "aligned" while the
  # GitHub issue is permanently drifted (stale title/body, no type label), and the
  # "already aligned" guard would refuse every retry. A later
  # `lcars file --complete` re-enters here (prdPending still true, so that guard
  # does NOT trip), regenerates prd.md / estimate.json idempotently, and cleanly
  # RETRIES the issue update — clearing prdPending only once it succeeds. (A gh
  # that is simply absent is NOT a failure: it degrades to a local align, exit 0,
  # exactly like grill-first.)
  if [ "$GH_FAILED" -eq 1 ]; then
    printf '%s\n' "$GH_NOTE" >&2
    return 1
  fi

  # --- write the FINAL state.json (grill-first shape; NO prdPending) ----------
  # This clears prdPending — the LAST write, so a failure above leaves the mission
  # parked for a clean re-run.
  local title_json="${TITLE//\\/\\\\}"; title_json="${title_json//\"/\\\"}"
  local OVERRIDE_LINE=""
  [ -n "$OV_SCOPE" ] && OVERRIDE_LINE="  \"modelOverride\": { \"scope\": \"$OV_SCOPE\", \"tier\": \"$OV_TIER\" },"
  # The engine carried forward from the parked state.json (do_park already applied
  # the --engine > $LCARS_WORKER_BIN precedence at park time — completing an
  # already-parked mission does NOT re-decide its engine).
  local WORKER_BIN_LINE; WORKER_BIN_LINE="$(_worker_bin_line "$WB")"
  local ATTACH_LINE=""
  if [ "${#ATTACH_RELS[@]}" -gt 0 ]; then
    local attach_items="" arel
    for arel in "${ATTACH_RELS[@]}"; do
      [ -n "$attach_items" ] && attach_items="$attach_items, "
      attach_items="$attach_items\"$arel\""
    done
    ATTACH_LINE="  \"attachments\": [$attach_items],"
  fi
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$ID"
    printf '  "type": "%s",\n' "$TYPE"
    printf '  "title": "%s",\n' "$title_json"
    printf '  "stage": "align",\n'
    printf '  "created": "%s",\n' "$CREATED"
    printf '  "model": "%s",\n' "$MODEL"
    [ -n "$OVERRIDE_LINE" ] && printf '%s\n' "$OVERRIDE_LINE"
    [ -n "$WORKER_BIN_LINE" ] && printf '%s\n' "$WORKER_BIN_LINE"
    [ -n "$ATTACH_LINE" ] && printf '%s\n' "$ATTACH_LINE"
    [ -n "$BASEFRESH_LINE" ] && printf '%s\n' "$BASEFRESH_LINE"
    printf '  "githubIssue": %s,\n' "${ISSUE:-null}"
    printf '  "branch": "%s",\n' "$BRANCH"
    printf '  "base": "%s"\n' "$BASE"
    printf '}\n'
  } >"$STATE"

  # CLI estimate readout (same as grill-first).
  local EST_CLI=""
  if [ -f "$RUN_BIN" ] && [ -f "$MISSION_DIR/estimate.json" ]; then
    EST_CLI="$(bash "$RUN_BIN" render-estimate --mission "$ID" --surface cli 2>/dev/null)"
  fi

  # S189: claim it. Idempotent — a mission parked (and claimed) earlier makes no
  # forge write here, so completing an already-owned mission costs nothing; a
  # park-time claim that FAILED gets a free retry at this second transfer point.
  _claim_note "${ISSUE:-}"

  local issue_line="(none — recorded locally only)"
  [ -n "$ISSUE" ] && issue_line="#$ISSUE"
  [ -n "$GH_NOTE" ] && echo "$GH_NOTE"
  [ -n "$EST_NOTE" ] && echo "$EST_NOTE"
  _print_note "${BRANCH_LAG:-}"
  echo "  Mission aligned: $ID"
  echo "  GitHub issue:    $issue_line"
  echo "  Type:            $TYPE"
  echo "  Stage:           align  (PRD written — ready for Research)"
  [ -n "$EST_CLI" ] && printf '%s\n' "$EST_CLI"
  echo "  Next:            run \`lcars run $ID\` to continue"
  return 0
}

# --- args -----------------------------------------------------------------
# --prd is REQUIRED. --adr is OPTIONAL: Align passes it ONLY for a complex
# Mission (an engineering ADR set); a trivial Mission ships no adr.md at all.
PRD_SRC=""
ADR_SRC=""
# Captain model override (session 62). A natural-language override the Align
# session normalized to a structured "<scope>:<tier>" string. scope ∈
# {all,reasoning,implementation}; tier ∈ {sonnet,opus}. Empty = no override.
MODEL_OVERRIDE=""
# Durable image attachments (S92). Each --attach <path> is a screenshot the
# captain pasted at File time; it is copied into the mission's attachments/ dir
# under a stable name, referenced by RELATIVE path in prd.md, and recorded in
# state.json — so a cold Stage worker can later READ it by path. Repeatable.
ATTACHMENTS=()
# --- Park & Align (S136) --------------------------------------------------
# A NEW pre-PRD lane. `lcars file --park "<idea>" [--engine …]` files a mission
# instantly with just the idea (no grill, no PRD, no estimate), parked at align
# with "prdPending": true; `lcars file --complete <id> --prd <path>` later runs
# the grill-completion (validate PRD, retitle+re-body the issue in place, add the
# type label, clear prdPending, estimate) — landing exactly where a grill-first
# filing lands. Absent both flags, this script is BYTE-IDENTICAL to grill-first.
MODE=""            # "" (grill-first) | park | complete
COMPLETE_ID=""     # the mission id for --complete
INITIALIZATION=0   # --initialization (S184: the Establish Vision mission)
IDEA_SRC=""        # --idea <file> (verbatim idea capture)
ENGINE=""          # --engine claude|copilot (parked mission's workerBin)
POSITIONAL=()      # bare args = the park idea text
while [ $# -gt 0 ]; do
  case "$1" in
    --park)  MODE="park"; shift ;;
    # S184 — the INITIALIZATION mission. `lcars file` is the ONE filer, so
    # Establish Vision files through it rather than minting a mission of its
    # own; this flag is the only thing that distinguishes the two. It does TWO
    # things and nothing else: it EXEMPTS this filing from the S183 foundation
    # gate (which exists to refuse NORMAL missions on a repo with no test
    # system — refusing the mission that BUILDS the test system would be the
    # gate eating its own purpose), and it stamps `missionType` into state.json
    # so S185 can recognise the mission whose first ticket may take the audited
    # scaffold waiver. Every other lane is untouched, and a mission filed
    # without it carries no `missionType` key at all.
    --initialization) INITIALIZATION=1; shift ;;
    --complete)   MODE="complete"; COMPLETE_ID="${2:-}"; shift 2 ;;
    --complete=*) MODE="complete"; COMPLETE_ID="${1#--complete=}"; shift ;;
    --idea)   IDEA_SRC="${2:-}"; shift 2 ;;
    --idea=*) IDEA_SRC="${1#--idea=}"; shift ;;
    --engine)   ENGINE="${2:-}"; shift 2 ;;
    --engine=*) ENGINE="${1#--engine=}"; shift ;;
    --prd)   PRD_SRC="${2:-}"; shift 2 ;;
    --prd=*) PRD_SRC="${1#--prd=}"; shift ;;
    --adr)   ADR_SRC="${2:-}"; shift 2 ;;
    --adr=*) ADR_SRC="${1#--adr=}"; shift ;;
    --model-override)   MODEL_OVERRIDE="${2:-}"; shift 2 ;;
    --model-override=*) MODEL_OVERRIDE="${1#--model-override=}"; shift ;;
    --attach)   ATTACHMENTS+=("${2:-}"); shift 2 ;;
    --attach=*) ATTACHMENTS+=("${1#--attach=}"); shift ;;
    --*)     die "unknown argument: $1" ;;
    *)       POSITIONAL+=("$1"); shift ;;
  esac
done

# Dispatch the two new lanes BEFORE the grill-first checks. Each owns its whole
# flow and exits; the grill-first path below runs only when neither flag is set,
# so its behaviour is unchanged (byte-identical).
if [ "$MODE" = "park" ]; then
  do_park
  exit $?
elif [ "$MODE" = "complete" ]; then
  do_complete
  exit $?
fi
# Grill-first: a bare positional argument is not accepted (only --prd drives it).
[ "${#POSITIONAL[@]}" -eq 0 ] || die "unexpected argument: ${POSITIONAL[0]} (grill-first filing takes --prd)."

[ -n "$PRD_SRC" ] || die "no PRD given — pass --prd <path> to a PRD file."
[ -f "$PRD_SRC" ] || die "PRD file not found: $PRD_SRC"

# --- validate the model override (session 62) ------------------------------
# Format is "<scope>:<tier>" with scope ∈ {all,reasoning,implementation} and
# tier ∈ {sonnet,opus}. A malformed value stops filing BEFORE anything is
# written (nothing partial), the same way a malformed PRD does.
OV_SCOPE=""
OV_TIER=""
if [ -n "$MODEL_OVERRIDE" ]; then
  OV_SCOPE="${MODEL_OVERRIDE%%:*}"
  OV_TIER="${MODEL_OVERRIDE#*:}"
  case "$MODEL_OVERRIDE" in
    *:*) : ;;
    *) die "malformed --model-override '$MODEL_OVERRIDE' — expected <scope>:<tier> (e.g. all:opus)." ;;
  esac
  case "$OV_SCOPE" in
    all|reasoning|implementation) : ;;
    *) die "invalid --model-override scope '$OV_SCOPE' — must be one of: all, reasoning, implementation." ;;
  esac
  case "$OV_TIER" in
    sonnet|opus) : ;;
    *) die "invalid --model-override tier '$OV_TIER' — must be one of: sonnet, opus." ;;
  esac
fi

# --- validate the engine pin (S147 DEFECT-1) -------------------------------
# Same shared gate the park lane runs, and for the same reason: a bogus --engine
# must stop the filing BEFORE anything is written. Previously the --prd lane
# never looked at --engine at all, so `--engine totally-bogus` filed happily and
# `--engine copilot` filed a mission with NO workerBin that then ran on the
# host-detected engine — real spend on an engine the captain did not pick.
_validate_engine

# --adr is optional, but if given it must point at a real file.
if [ -n "$ADR_SRC" ]; then
  [ -f "$ADR_SRC" ] || die "ADR file not found: $ADR_SRC"
fi

# Attachments are optional, but if given each must point at a real file — checked
# BEFORE anything is written so a bad --attach stops filing with nothing partial,
# the same way a malformed PRD/ADR does (S92).
if [ "${#ATTACHMENTS[@]}" -gt 0 ]; then
  for a in "${ATTACHMENTS[@]}"; do
    [ -n "$a" ] || die "empty --attach path given."
    [ -f "$a" ] || die "attachment file not found: $a"
  done
fi

# --- locate the repo + state dir ------------------------------------------
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" \
  || die "not inside a git repository — run this from a repo root."
case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac

LCARS_DIR="$GIT_DIR/lcars"
MISSIONS_DIR="$LCARS_DIR/missions"
CONFIG="$LCARS_DIR/config.json"

# S183 — no foundation, no normal mission. Checked before the PRD is even read,
# so the captain hears about the repo rather than about his PRD — and, fix round
# 1 (D7), BEFORE `mkdir -p "$MISSIONS_DIR"`. Creating the missions directory
# first meant a REFUSED filing left `.git/lcars/missions/` behind in a repo that
# had none, contradicting the gate header's own promise that a refusal leaves the
# repo untouched.
_foundation_gate
mkdir -p "$MISSIONS_DIR"

# --- validate the PRD has every required section --------------------------
# Each entry is "human label" + the PRD label to look for.
# S176 — accepted in BOTH shapes (bold inline label OR markdown heading), by
# the SAME reader the extraction below uses. See lcars_prd_has_field.
require_section() {
  lcars_prd_has_field "$PRD_SRC" "$2" || die_prd "PRD is missing the '$1' section — Align must produce it before filing."
}
require_section "Mission title"      'Mission'
require_section "Type"               'Type'
require_section "Goal"               'Goal'
require_section "Acceptance Criteria" 'Acceptance Criteria'
require_section "Out of Scope"       'Out of Scope'
require_section "Constraints"        'Constraints'

# S175 — and the design brief's own OPEN QUESTIONS must survive this boundary.
# Same gate as the --complete lane (_validate_prd), reading the SOURCE attachment
# paths since nothing is staged yet. A no-op for every mission with no concept
# doc and for one whose brief left nothing open, so their filing is untouched.
if [ "${#ATTACHMENTS[@]}" -gt 0 ]; then
  QGATE_MSG="$(lcars_prd_questions_gate "$PRD_SRC" "${ATTACHMENTS[@]}" 2>&1)" \
    || die_prd "$QGATE_MSG"
fi

# --- when an ADR set is provided, shape-check it ---------------------------
# SHAPE validation only — NOT depth policy. Whether a Mission is complex enough
# to warrant ADRs is Align's judgment (the prompt), not the script's. But IF
# Align hands us an adr.md, each ADR's required sections must be present:
# Context / Decision / Alternatives considered / Consequences. A malformed ADR
# stops the filing the same way a malformed PRD does (nothing is written).
if [ -n "$ADR_SRC" ]; then
  require_adr_section() {
    grep -q "$2" "$ADR_SRC" || die_prd "ADR is missing the '$1' section — each ADR needs Context / Decision / Alternatives considered / Consequences."
  }
  require_adr_section "Context"      '\*\*Context:\*\*'
  require_adr_section "Decision"     '\*\*Decision:\*\*'
  require_adr_section "Alternatives" '\*\*Alternatives considered:\*\*'
  require_adr_section "Consequences" '\*\*Consequences:\*\*'
fi

# --- derive title + type from the PRD -------------------------------------
TITLE="$(lcars_prd_field "$PRD_SRC" 'Mission' | head -1)"
[ -n "$TITLE" ] || die_prd "could not read the Mission title from the PRD."

TYPE="$(lcars_prd_field "$PRD_SRC" 'Type' | head -1 \
        | tr 'A-Z' 'a-z' | tr -cd 'a-z')"
case "$TYPE" in
  feature|bug) : ;;
  *) die_prd "PRD Type must be 'feature' or 'bug' (got: '${TYPE:-empty}')." ;;
esac

# --- mint the mission ID (per-day sequence + the clone fingerprint) -------
# S196 — the SAME minter the --park/--complete lane's _mint_id uses (and the
# same one `lcars log` uses): lcars_mint_mission_id in lcars-common.sh. The id
# carries a short per-clone tag because it names a SHARED thing — the branch
# `lcars/<id>` on the remote — while its sequence number is counted from purely
# local information. See that function for the capstone collision it fixes.
ID="$(lcars_mint_mission_id "$MISSIONS_DIR" "$DATE" "$(lcars_clone_fingerprint "$CONFIG")")"

MISSION_DIR="$MISSIONS_DIR/$ID"
mkdir -p "$MISSION_DIR"

# --- give the Mission its own branch --------------------------------------
# The vision's rule: each Mission gets its own branch. Create it now, off the
# branch we're currently on (the base the PR will eventually target), and record
# both in state.json so Implement can commit to it and `lcars approve` can push
# it + open the PR with --head/--base. We do NOT switch to it here — the working
# tree of the captain's repo stays exactly as it was; Implement checks it out
# when it's time to commit. Branch creation is best-effort: a repo with no
# commits (nothing to branch from) just gets a warning, and Implement creates
# the branch on first commit.
BRANCH="lcars/$ID"
# S160 — the SHARED base resolution (see _make_branch): one function, so the
# board's pre-flight line and this filing can never disagree about which branch
# the Mission is cut from.
BASE="$(lcars_base_current_branch)"
# S158 — bring BASE up to date BEFORE the branch is cut. This is the whole point:
# `lcars/<id>` must start from the tree the rest of the world sees, or every
# downstream Stage reasons about code that no longer exists. The guard never
# blocks filing, never touches a dirty tree, and prints its own legible reason
# whenever it refuses. BASEFRESH_LINE is the record write_state persists.
ensure_base_current "$BASE"
BRANCH_NOTE=""
BRANCH_ORIGIN=""   # reused | new | "" (none created) — round 2, D3
if "$GIT_BIN" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  if "$GIT_BIN" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    BRANCH_NOTE="  ⚠ branch $BRANCH already exists — reusing it."
    BRANCH_ORIGIN="reused"
  elif ! "$GIT_BIN" branch "$BRANCH" >/dev/null 2>&1; then
    BRANCH_NOTE="  ⚠ could not create branch $BRANCH — create it before Implement."
  else
    BRANCH_ORIGIN="new"
  fi
else
  BRANCH_NOTE="  ⚠ repo has no commits yet — branch $BRANCH not created; Implement will create it on first commit."
fi
BRANCH_SOURCE="$(_branch_source_desc)"
# Both of these are claims about THIS MISSION's branch, so they are decided AFTER
# it exists: whether the ✓ "cut from the CURRENT tree" line is even true, and
# whether state.json may say the mission sits on baseSha (S158 round 1, D6).
_append_branch_note
BASEFRESH_LINE="$(lcars_base_state_line "$BRANCH")"

# --- write prd.md ---------------------------------------------------------
cat "$PRD_SRC" >"$MISSION_DIR/prd.md"

# --- stage durable image attachments (S92) --------------------------------
# Copy each --attach into attachments/ under a stable, deterministic name
# (attachment-NN.<ext>, NN zero-padded by order, ext from the source), append an
# attachments section to prd.md listing each by RELATIVE path, and collect the
# relative paths for state.json below. mkdir only when ≥1 attach is given; no
# attachments ⇒ nothing written (byte-identical to before).
#
# The section's WORDING is not spelled here. prd.md is the mission's own
# document and its GitHub issue body, and a holodeck hand-off travels this same
# road carrying a `mockup.html` — so the heading comes from the one shared rule
# (lcars_attach_prd_section, lcars-init/lcars-common.sh) that the cold-Stage
# prompt block and `lcars log` also derive from. Image-only output is unchanged
# byte for byte.
ATTACH_RELS=()
if [ "${#ATTACHMENTS[@]}" -gt 0 ]; then
  mkdir -p "$MISSION_DIR/attachments"
  an=0
  for asrc in "${ATTACHMENTS[@]}"; do
    an=$((an + 1))
    aext=""
    case "$asrc" in *.*) aext=".${asrc##*.}" ;; esac
    arel="$(printf 'attachments/attachment-%02d%s' "$an" "$aext")"
    cp "$asrc" "$MISSION_DIR/$arel"
    ATTACH_RELS+=("$arel")
  done
  lcars_attach_prd_section "${ATTACH_RELS[@]}" >>"$MISSION_DIR/prd.md"
  _lcars_inject_anchor_rule "$MISSION_DIR" "${ATTACH_RELS[@]}"
fi

# --- write adr.md (complex Missions only) ---------------------------------
# Mirrors how --prd is persisted: copy the (already shape-checked) ADR set into
# the mission dir as the durable adr.md every downstream worker (EXCEPT research
# agents) may read. A trivial Mission passes no --adr, so no adr.md is written.
if [ -n "$ADR_SRC" ]; then
  cat "$ADR_SRC" >"$MISSION_DIR/adr.md"
fi

# --- resolve the model (config.json wins, else env, else default) ---------
MODEL=""
if [ -f "$CONFIG" ]; then
  MODEL="$(sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)"
fi
[ -n "$MODEL" ] || MODEL="${LCARS_MODEL:-claude-sonnet}"

# --- write state.json (session 61: BEFORE the estimator + issue) -----------
# The estimator (run.sh `estimate`) resolves the mission via locate_mission, which
# REQUIRES state.json to exist. To render the estimate INTO the issue body we must
# run the estimator before the issue is created — so state.json has to be written
# first too. We write it now with githubIssue=null, then patch in the real issue
# number after gh creates the issue (state_set_issue, below). Every other field is
# final here. `write_state <issue-or-null>` emits the file.
title_json="${TITLE//\\/\\\\}"
title_json="${title_json//\"/\\\"}"
# The captain model override object (session 62), emitted only when set. The
# downstream S58 resolver reads modelOverride.scope / modelOverride.tier and pins
# the in-scope stages to that tier (above the estimate, below the env pin).
OVERRIDE_LINE=""
if [ -n "$OV_SCOPE" ]; then
  OVERRIDE_LINE="  \"modelOverride\": { \"scope\": \"$OV_SCOPE\", \"tier\": \"$OV_TIER\" },"
fi
# The chosen engine (S67, precedence fixed S147). When the captain picks an engine
# in the File modal the daemon threads it to file.sh as $LCARS_WORKER_BIN; an
# explicit `--engine` on the command line is stronger still and wins over it.
# Persist the winner as state.json's `workerBin` so the board can show it and
# `lcars run` can be fed it on Start — the engine survives file→persist→start→run.
# Neither set ⇒ no field (no regression / host-detect stays in charge). The shared
# helpers below are the SAME ones do_park uses, so the two lanes cannot drift.
WORKER_BIN_LINE="$(_worker_bin_line "$(_resolve_worker_bin)")"
# The durable attachments array (S92), emitted only when ≥1 attachment was staged
# — mirroring the OVERRIDE_LINE / WORKER_BIN_LINE optional-line pattern so a
# no-attachment mission's state.json is byte-identical (no attachments key). Each
# entry is a RELATIVE path under the mission dir (attachments/attachment-NN.ext).
ATTACH_LINE=""
if [ "${#ATTACH_RELS[@]}" -gt 0 ]; then
  attach_items=""
  for arel in "${ATTACH_RELS[@]}"; do
    [ -n "$attach_items" ] && attach_items="$attach_items, "
    attach_items="$attach_items\"$arel\""
  done
  ATTACH_LINE="  \"attachments\": [$attach_items],"
fi
write_state() { # issue-json (a number or the literal `null`)
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$ID"
    printf '  "type": "%s",\n' "$TYPE"
    printf '  "title": "%s",\n' "$title_json"
    # S184 — the mission TYPE, present ONLY on an initialization mission, so
    # every mission filed before this round (and every normal one after it)
    # carries a byte-identical state.json.
    [ "${INITIALIZATION:-0}" = "1" ] && printf '  "missionType": "initialization",\n'
    printf '  "stage": "align",\n'
    printf '  "created": "%s",\n' "$NOW"
    printf '  "model": "%s",\n' "$MODEL"
    [ -n "$OVERRIDE_LINE" ] && printf '%s\n' "$OVERRIDE_LINE"
    [ -n "$WORKER_BIN_LINE" ] && printf '%s\n' "$WORKER_BIN_LINE"
    [ -n "$ATTACH_LINE" ] && printf '%s\n' "$ATTACH_LINE"
    [ -n "$BASEFRESH_LINE" ] && printf '%s\n' "$BASEFRESH_LINE"
    printf '  "githubIssue": %s,\n' "${1:-null}"
    printf '  "branch": "%s",\n' "$BRANCH"
    printf '  "base": "%s"\n' "$BASE"
    printf '}\n'
  } >"$MISSION_DIR/state.json"
}
write_state null

# --- run the end-of-Align estimator (session 59) --------------------------
# REORDERED in session 61 to run BEFORE the issue is created, so estimate.json
# exists when the issue body is composed and the estimate can be rendered into
# BOTH captain surfaces (the issue body + the CLI readout). cmd_estimate resolves
# the mission via locate_mission (needs state.json — written just above) and reads
# prd.md (already written). The estimator is STRICTLY OPTIONAL and must NEVER block
# filing: it mirrors the gh-missing degradation below. If run.sh is missing, or it
# produces no estimate.json (worker unavailable, malformed output), we print a note
# and STILL file the mission — every stage then falls back to its legacy model
# exactly as before this feature existed, and no "## Estimate" section is rendered
# (an absent estimate.json is treated exactly like an absent adr.md).
EST_NOTE=""
if [ -f "$RUN_BIN" ]; then
  if bash "$RUN_BIN" estimate --mission "$ID" >/dev/null 2>&1 \
       && [ -f "$MISSION_DIR/estimate.json" ]; then
    : # estimate produced — nothing to note.
  else
    EST_NOTE="  ⚠ estimator unavailable — mission filed with default per-stage models."
  fi
else
  EST_NOTE="  ⚠ estimator driver not found ($RUN_BIN) — mission filed with default per-stage models."
fi

# --- render the estimate's "## Estimate" section for the issue body (S61) --
# Ask the lcars-run driver to format estimate.json into the issue-surface markdown
# block, in the ACTIVE CLI's native cost unit. render-estimate prints NOTHING and
# exits non-zero when estimate.json is absent, so EST_ISSUE stays empty and the
# body is prd[+adr] only — same degradation pattern as an absent adr.md.
EST_ISSUE=""
if [ -f "$RUN_BIN" ] && [ -f "$MISSION_DIR/estimate.json" ]; then
  EST_ISSUE="$(bash "$RUN_BIN" render-estimate --mission "$ID" --surface issue 2>/dev/null)"
fi

# --- open the GitHub issue ------------------------------------------------
ISSUE=""
GH_NOTE=""
if command -v "$GH_BIN" >/dev/null 2>&1; then
  # Build the issue body. PRD always comes first. For a complex Mission an
  # adr.md exists; append the ADR set after a `\n\n---\n\n` separator so the
  # board reader sees the architectural decisions too. When an estimate exists,
  # append its "## Estimate" section last, after another `\n\n---\n\n` rule. The
  # on-disk prd.md and adr.md stay separate artifacts — only the issue BODY
  # combines them. Order is always prd → adr → Estimate.
  # LANE 4 (grill-first). ONE composer (skills/lcars-run/issue-body.sh) — the
  # body above is what it emits, byte for byte, plus the appended envelope.
  # No overrides: write_state ran above, so state.json already carries this
  # mission's final type / branch / base / workerBin / attachments.
  BODY_TMP="$(mktemp "$MISSION_DIR/.issue-body.XXXXXX")"
  lcars_issue_body_compose "$MISSION_DIR" align "$EST_ISSUE" >"$BODY_TMP"
  BODY_FILE="$BODY_TMP"
  trap 'rm -f "$BODY_TMP"' EXIT
  url="$("$GH_BIN" issue create \
          --title "$TITLE" \
          --body-file "$BODY_FILE" \
          --label "lcars:align,lcars:$TYPE,lcars:mission" 2>/dev/null)"
  # gh prints the new issue's URL; the trailing path segment is its number.
  num="${url##*/}"
  case "$num" in
    ''|*[!0-9]*) : ;;
    # Remember the body that actually reached GitHub — the S188 regression
    # guard's baseline (see skills/lcars-run/issue-body.sh). Recorded BEFORE the
    # temp file is removed, and only when gh really opened the issue.
    *) lcars_issue_body_record "$MISSION_DIR" "$BODY_TMP" ;;
  esac
  if [ -n "$BODY_TMP" ]; then rm -f "$BODY_TMP"; trap - EXIT; fi
  case "$num" in
    ''|*[!0-9]*) GH_NOTE="  ⚠ gh issue create failed — mission filed locally; re-run after fixing gh." ;;
    *) ISSUE="$num" ;;
  esac
else
  GH_NOTE="  ⚠ gh CLI not found — mission filed locally without a GitHub issue."
fi

# --- record the issue number in state.json --------------------------------
# state.json was written with githubIssue=null before the estimator (so
# locate_mission could resolve the mission). Now that gh has (maybe) created the
# issue, rewrite it with the real number — or leave null when gh was missing/failed.
write_state "${ISSUE:-null}"

# S189: the grill-first lane's claim — the captain who filed it owns it.
_claim_note "${ISSUE:-}"

# --- render the estimate's compact summary for the CLI readout (S61) -------
# Same render-estimate driver, the cli surface this time: a compact, two-space-
# indented block (Estimate summary + model mix + one-line rationale) in the active
# CLI's native cost unit. Absent estimate.json ⇒ empty (no readout block), exactly
# the degradation parity the EST_NOTE already covers.
EST_CLI=""
if [ -f "$RUN_BIN" ] && [ -f "$MISSION_DIR/estimate.json" ]; then
  EST_CLI="$(bash "$RUN_BIN" render-estimate --mission "$ID" --surface cli 2>/dev/null)"
fi

# --- confirmation summary -------------------------------------------------
if [ -n "$ISSUE" ]; then
  issue_line="#$ISSUE"
else
  issue_line="(none — file locally only)"
fi

[ -n "$GH_NOTE" ] && echo "$GH_NOTE"
[ -n "$EST_NOTE" ] && echo "$EST_NOTE"
_print_note "${BRANCH_NOTE:-}"
echo "  Mission filed: $ID"
echo "  GitHub issue:  $issue_line"
echo "  Branch:        $BRANCH (off ${BRANCH_SOURCE:-$BASE})"
echo "  Stage:         align"
# The estimate readout (S61): the compact Estimate summary + model mix + rationale,
# in the active CLI's native cost unit. Empty when no estimate.json was produced.
[ -n "$EST_CLI" ] && printf '%s\n' "$EST_CLI"
echo "  Next:          run \`lcars run $ID\` to continue"
