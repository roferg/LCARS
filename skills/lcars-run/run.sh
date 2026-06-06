#!/usr/bin/env bash
#
# lcars run — advance a Mission one Stage. This build implements the Research,
# Validate, and Plan stages (align → validate → plan → plan-review).
#
# `lcars run <id>` dispatches on state.json.stage. A mission filed by
# `lcars file` sits at stage "align" (Align already happened conversationally),
# so the next Stage to execute is Research. Research has two halves:
#
#   • Claude (per SKILL.md) reads prd.md, generates 0–20 research questions,
#     and spawns one STATELESS subagent per question. Each agent gets only its
#     question text and returns { question, recommendation, supporting_points }.
#   • This script does the mechanical, testable parts, via two subcommands:
#
#       gate  --mission <id> --questions <file>
#             Branch on the question count BEFORE any agent runs:
#               0          → skip Research, advance the mission (prints GATE: skip)
#               1..20      → dispatch that many agents       (prints GATE: dispatch N)
#               >20        → stop and ask the human          (prints GATE: too-many N, exit 3)
#
#       save  --mission <id> --responses <dir>
#             Persist the agents' response JSON to research/<n>.json, then
#             advance the mission.
#
# "Advance the mission" means: set state.json.stage to "validate" AND move the
# GitHub label from lcars:align to lcars:validate, so the on-disk state and the
# board's label always agree on one answer — the Stage `lcars run` will execute
# next. A freshly filed mission sits at "align" (Align already happened in
# `lcars file`), so `lcars run` treats "align" as the signal to run Research and
# lands the card in the Validate column when it's done.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN   the gh binary  (default: gh)
#   LCARS_GIT_BIN  the git binary (default: git)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
GIT_BIN="${LCARS_GIT_BIN:-git}"
# The cold-worker binary. Every headless Stage's LLM work runs as a one-shot
# invocation of this CLI — defaulting to whichever CLI you launched LCARS under
# (`claude`). Swapping it is the whole CLI-portability story (BUG-003); tests
# point it at a stub that echoes canned artifacts so the plumbing runs token-free.
WORKER_BIN="${LCARS_WORKER_BIN:-claude}"
# The test runner the Implement red gate invokes to prove the Test Writer's
# suite FAILS before the Implementer runs. Env-injectable (like LCARS_GH_BIN) so
# unit tests can drive a fake red→green transition; otherwise sourced from the
# repo's config.json (`testCommand`, written by `lcars init`). See red_gate_ok.
TEST_CMD_ENV="${LCARS_TEST_CMD:-}"
# Re-invocation of this very script, used by the Stage drivers to reuse the
# already-tested persistence subcommands (gate/save/validate-*/plan-save/…)
# rather than duplicate their logic.
SELF="${BASH_SOURCE[0]}"
# The skill's own directory, and the per-Stage worker prompt templates under it.
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
STAGES_DIR="$SKILL_DIR/stages"
# The host-integration adapter — the ONE place that speaks to a forge. Every
# GitHub call funnels through it so the integration is swappable (BUG-003). It
# sits beside this script; $LCARS_HOST_ADAPTER overrides the path so tests can
# stub the whole adapter. The adapter selects its host via $LCARS_HOST_BIN
# (default "github") and the github host shells out to ${LCARS_GH_BIN:-gh}.
HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SKILL_DIR/host-adapter.sh}"
host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@"; }
# The walk-away notification hook. The driver calls this ONCE at a human gate
# (awaiting-human or verify). Defaults to the bundled notify.sh; env-injectable
# (like LCARS_GH_BIN) so tests assert the call without sending anything.
NOTIFY_BIN="${LCARS_NOTIFY:-$SKILL_DIR/notify.sh}"
# A malformed worker output stops the Stage; the driver re-dispatches up to this
# many attempts before surfacing failure (no silent advance).
MAX_WORKER_TRIES="${LCARS_WORKER_TRIES:-3}"
MAX_QUESTIONS=20
MAX_REVIEW_ROUNDS=3
RELABEL_NOTE=""
# The auto-advance summary rule.
SEP="─────────────────────────────────────────────"

die() { printf 'lcars run: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as file.sh / status.sh) ----------
json_str() { # file key  → first matching "key": "value"
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}
json_raw() { # file key  → first matching bare token (number/null/bool)
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

# --- tiny JSON writers (pretty, one-field-per-line state.json) --------------
# state.json is written one field per line (see file.sh), so we edit it by the
# line. New fields are inserted right after the opening brace — always valid
# because `id` always follows. Untrusted text (question text) is JSON-escaped
# and handed to awk via the environment so awk never reinterprets its escapes.
json_escape() { # string → backslash/quote-escaped (printed)
  local s="$1"
  s="${s//\\/\\\\}"   # backslashes first…
  s="${s//\"/\\\"}"   # …then double-quotes
  printf '%s' "$s"
}

# --- the Mission event log (append-only JSONL) -----------------------------
# A per-Mission, append-only event stream at $MISSION_DIR/events.jsonl. The
# HARNESS (this script, around its cold-worker calls) emits one short JSON line
# per stage transition / gate so a tail or scrollback shows progress AS IT
# HAPPENS — not just an accumulated summary at halt. It is CLI/host-agnostic:
# events are emitted by bash here, never by the worker and never parsed from
# worker stdout.
#
#   emit_event <type> <stage> <detail>
#
# Line shape (fixed key order, jq-free):
#   {"ts":<unix>,"mission":"<id>","stage":"<stage>","type":"<type>","detail":"<text>"}
#
# Each line is one short single line (well under PIPE_BUF, ~4096 bytes) written
# in APPEND mode, so concurrent appends from nested stage subprocesses stay
# atomic. NO-OP-SAFE: with no located mission ($MISSION_DIR unset/empty) it does
# nothing and returns 0. The timestamp is overridable via $LCARS_NOW so tests
# are deterministic.
#
#   emit_event <type> <stage> <detail> [key=value ...]
#
# The trailing key=value pairs (Session 26+) become a MACHINE-READABLE
# "data":{...} object appended to the line in the order given (fixed key order),
# jq-free. A value matching ^[0-9]+$ is rendered as an UNQUOTED number (e.g.
# "wave":2); anything else is JSON-escaped and quoted (e.g. "phase":"test-writer")
# — so Session 27 can parse "Wave x/y" / "k of n" / avg-per-ticket without jq.
# CRITICAL REGRESSION: with NO data pairs the line is BYTE-IDENTICAL to Session
# 25 — no "data" key at all (the EV1–EV6 tests pin this).
emit_event() { # type stage detail [key=value ...]
  [ -n "${MISSION_DIR:-}" ] || return 0
  local ts type stage detail mid
  ts="${LCARS_NOW:-$(date +%s)}"
  type="$(json_escape "${1:-}")"
  stage="$(json_escape "${2:-}")"
  detail="$(json_escape "${3:-}")"
  mid="$(json_escape "${MISSION_ID:-}")"
  shift 3 2>/dev/null || shift $#   # the rest are key=value data pairs (may be none)

  # Build the optional "data":{...} suffix from the trailing pairs. No pairs →
  # empty string → the printf emits the Session-25 line unchanged.
  local data="" sep="" pair k v
  for pair in "$@"; do
    k="${pair%%=*}"; v="${pair#*=}"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
      data="$data$sep\"$(json_escape "$k")\":$v"          # unquoted number
    else
      data="$data$sep\"$(json_escape "$k")\":\"$(json_escape "$v")\""   # quoted string
    fi
    sep=","
  done
  [ -n "$data" ] && data=",\"data\":{$data}"

  printf '{"ts":%s,"mission":"%s","stage":"%s","type":"%s","detail":"%s"%s}\n' \
    "$ts" "$mid" "$stage" "$type" "$detail" "$data" >>"$MISSION_DIR/events.jsonl"
}
# --- durable dedup/indexing helpers (derive from events.jsonl, not a local) --
# The Implement stage is RE-INVOKED on real runs (a manual `lcars run` retry, or
# the `lcars respond` → `lcars run` resume after a flagged ticket). A fresh
# process restarts any in-process guard, so wave_start / ticket_start would
# re-emit and ticket_attempt would restart at 1. events.jsonl is the durable
# per-Mission log, so dedup + indexing must read IT — never a process-local.
#
# event_seen <type> <data-fragment-regex> → 0 if events.jsonl already holds a
# line of that type whose body matches the (extended-regex) fragment. No-op-safe
# when the file doesn't exist yet (returns 1 = not seen). jq-free, same style as
# the rest of run.sh. Tickets in a wave run SEQUENTIALLY, so reading the log just
# before each emit is race-free.
event_seen() { # type data-fragment-regex
  [ -n "${MISSION_DIR:-}" ] || return 1
  local f="$MISSION_DIR/events.jsonl"
  [ -f "$f" ] || return 1
  grep -E "\"type\":\"$1\"" "$f" 2>/dev/null | grep -Eq "$2"
}
# event_count <type> <data-fragment-regex> → how many lines of that type match the
# fragment. 0 (and success) when the file is absent. Used to NUMBER ticket_attempt
# cumulatively across invocations: the next index is 1 + this count.
event_count() { # type data-fragment-regex
  if [ -n "${MISSION_DIR:-}" ] && [ -f "$MISSION_DIR/events.jsonl" ]; then
    grep -E "\"type\":\"$1\"" "$MISSION_DIR/events.jsonl" 2>/dev/null \
      | grep -Ec "$2"
  else
    echo 0
  fi
}
state_del() { # key   — drop the field's line if present (no-op otherwise)
  local tmp; tmp="$(mktemp)"
  grep -v "\"$1\"[[:space:]]*:" "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}
state_set_str() { # key value   — add or replace a string field
  state_del "$1"
  local esc tmp; esc="$(json_escape "$2")"; tmp="$(mktemp)"
  K="$1" V="$esc" awk 'NR==1{print; printf "  \"%s\": \"%s\",\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}
state_set_raw() { # key token   — add or replace a bare field (true/false/number)
  state_del "$1"
  local tmp; tmp="$(mktemp)"
  K="$1" V="$2" awk 'NR==1{print; printf "  \"%s\": %s,\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# --- locate the mission ----------------------------------------------------
# Resolves MISSION_DIR / STATE for the given id, mirroring file.sh's .git
# resolution. Dies if the mission or its state.json is absent.
locate_mission() {
  local id="$1" gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  MISSION_DIR="$gitdir/lcars/missions/$id"
  STATE="$MISSION_DIR/state.json"
  # Repo-level config (lcars init writes it) + the working-tree root the red gate
  # runs the test suite from.
  LCARS_CFG="$gitdir/lcars/config.json"
  REPO_ROOT="$("$GIT_BIN" rev-parse --show-toplevel 2>/dev/null)"; [ -n "$REPO_ROOT" ] || REPO_ROOT="$PWD"
  [ -d "$MISSION_DIR" ] || die "no mission '$id' under .git/lcars/missions/ — check the id (or run \`lcars file\` first)."
  [ -f "$STATE" ]       || die "mission '$id' has no state.json — its state is corrupt."
}

# --- the durable repo context source (the one-time static BASE) -------------
# Every Align / Validate / Plan / Plan-Review / Implement worker reads the SAME
# declarative repo facts instead of re-deriving them each run. We resolve that
# source ONCE and reuse it. Resolution order (the spec):
#   1. CONTEXT.md at the repo root            → use it; generate NO pack.
#   2. .git/lcars/context-pack.md (generated) → use it.
#   3. neither                                → generate the pack via ONE cold
#      worker, then use it.
# Generation is LAZY: it happens on the first Stage / Align that needs the
# source, never at `lcars init`. The pack lives ONLY inside .git/ — the target
# repo's working tree and tracked files are NEVER touched (no CONTEXT.md is ever
# created). Research agents must NEVER see this source: it is shared repo facts,
# safe for the declarative Stages but off-limits to the single-question agents.
#
# Sets CONTEXT_GITDIR / CONTEXT_REPO_ROOT / CONTEXT_PACK_PATH (the canonical
# pack location) for the caller.
context_paths() {
  local gitdir
  gitdir="$("$GIT_BIN" rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  CONTEXT_GITDIR="$gitdir"
  CONTEXT_REPO_ROOT="$("$GIT_BIN" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$CONTEXT_REPO_ROOT" ] || CONTEXT_REPO_ROOT="$PWD"
  CONTEXT_PACK_PATH="$gitdir/lcars/context-pack.md"
}

# Generate the pack via ONE cold worker. Mirrors spawn_worker exactly: the
# worker writes to a `mktemp -d` SCRATCH file (its expanded absolute path baked
# into the prompt as literal text — no $VAR for the headless worker to expand),
# then BASH copies that scratch file into the durable pack path. The worker never
# touches `.git/` (the Write tool auto-denies any `.git/` path in headless `-p`
# mode) and never needs to resolve an env token. cwd stays at the repo root so
# the worker's read-only repo access works. Stays CLI-agnostic.
generate_context_pack() { # pack-path
  local pack="$1" scratch out prompt tools
  mkdir -p "$(dirname "$pack")"
  scratch="$(mktemp -d)"
  out="$scratch/context-pack.md"
  prompt="$(cat "$STAGES_DIR/context-pack.md")

Write your context pack to EXACTLY: $out"
  tools="$(worker_tools repo-read)"
  LCARS_WORK_OUT="$scratch" LCARS_WORKER_ROLE="context-pack" \
    "$WORKER_BIN" -p "$prompt" --allowedTools "$tools" --output-format text \
    >"$scratch/.worker.out" 2>"$scratch/.worker.err" || true
  # BASH (which CAN write into `.git/`) lands the durable pack from scratch.
  [ -f "$out" ] && cp "$out" "$pack"
  rm -rf "$scratch"
}

# The SINGLE resolver. Resolves the durable context source and PRINTS its path
# (one line), generating the pack lazily-once via a cold worker if neither a
# repo-root CONTEXT.md nor a prior pack exists. In-process (no subprocess) so it
# is reused identically by the `context-source` subcommand (Align flow, via
# lcars-file) AND the cold Stage drivers below — one implementation, no
# duplication.
resolve_context_source() {
  context_paths
  # 1. CONTEXT.md wins — even if added after `lcars init`. Filesystem check, not
  #    config, so a CONTEXT.md dropped in later is honoured immediately.
  if [ -f "$CONTEXT_REPO_ROOT/CONTEXT.md" ]; then
    printf '%s\n' "$CONTEXT_REPO_ROOT/CONTEXT.md"
    return 0
  fi
  # 2. Already-generated pack — reuse, never regenerate.
  if [ -f "$CONTEXT_PACK_PATH" ]; then
    printf '%s\n' "$CONTEXT_PACK_PATH"
    return 0
  fi
  # 3. Generate it once, via a single cold worker, then use it.
  require_worker
  generate_context_pack "$CONTEXT_PACK_PATH"
  [ -f "$CONTEXT_PACK_PATH" ] \
    || die "the context-pack worker produced no $CONTEXT_PACK_PATH — context source unresolved, Stage stopped."
  printf '%s\n' "$CONTEXT_PACK_PATH"
  return 0
}

# `run.sh context-source` — the public subcommand lcars-file's Align flow calls.
cmd_context_source() { resolve_context_source; }

# Resolve the context source for a Stage driver and echo a block to append to
# its `extra` (the artifact PATHS the cold worker reads). This is how the shared
# repo facts reach Validate / Plan / Plan-Review / Implement — by PATH only,
# consistent with cold-worker isolation. NEVER call this from Research.
context_extra_block() {
  local src
  src="$(resolve_context_source 2>/dev/null)" || return 0
  [ -n "$src" ] || return 0
  printf '
## Repo context (declarative repo facts — read for grounding)
- %s' "$src"
}

# Each Stage runs only when the Mission is parked at the stage that feeds it,
# so we never relabel or overwrite a mission mid-flight. Research runs on
# `align`; Validate runs on `validate`.
require_stage() { # wanted-stage
  local stage; stage="$(json_str "$STATE" stage)"
  [ "$stage" = "$1" ] || die "mission is at stage '${stage:-unknown}', not '$1' — this Stage only runs on a mission parked at '$1'."
}

# --- rewrite state.json's stage field in place (portable sed) --------------
set_stage() {
  local newstage="$1" tmp
  tmp="$(mktemp)"
  sed "s/\(\"stage\"[[:space:]]*:[[:space:]]*\"\)[^\"]*\(\"\)/\1$newstage\2/" "$STATE" >"$tmp" \
    && mv "$tmp" "$STATE"
}

# --- gh relabel: keep the board's label in step with the on-disk stage -----
# Best-effort: a missing issue / missing gh / failed edit never blocks the
# local stage change — it just leaves a note telling the captain what to fix
# by hand. Add/remove lists are space-separated (labels carry no spaces).
gh_relabel() { # "add labels…"  "remove labels…"
  local add="$1" rem="$2" l
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null)
      RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped relabel (local-only mission)."
      return 0 ;;
  esac

  local hand="+${add// /,} -${rem// /,}"
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    # The adapter performs the actual relabel (best-effort, never blocks); we
    # only keep the local note when its forge call fails, so the captain knows
    # what to fix by hand. The note path is preserved verbatim from before.
    if ! host issue-relabel "$issue" --add "$add" --remove "$rem"; then
      RELABEL_NOTE="  ⚠ gh issue edit failed — relabel #$issue by hand ($hand)."
    fi
  else
    RELABEL_NOTE="  ⚠ gh not found — skipped relabel; do it by hand (#$issue: $hand)."
  fi
}

# --- advance Research: stage pointer → validate, label align → validate -----
advance() {
  set_stage "validate"
  gh_relabel "lcars:validate" "lcars:align"
}

# --- subcommand: gate ------------------------------------------------------
cmd_gate() {
  locate_mission "$MISSION_ID"
  require_stage align

  local n=0
  if [ -n "$QFILE" ] && [ -f "$QFILE" ]; then
    n="$(grep -cve '^[[:space:]]*$' "$QFILE")"
  fi

  if [ "$n" -eq 0 ]; then
    advance
    echo "GATE: skip"
    echo "  No research questions — the PRD is unambiguous. Skipping Research."
    echo "  Stage:  validate"
    [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
    exit 0
  fi

  if [ "$n" -gt "$MAX_QUESTIONS" ]; then
    # Over the cap → escalate to the human, walk-away style (same awaiting-human
    # gate shape as validate-pause). The Mission's STAGE pointer stays "align"
    # (Research runs on align, so a resume re-enters Research), but the BOARD
    # label flips align → research so the paused card sits in the Research column
    # it is actually stuck in — not back in Align. Then overlay awaiting-human.
    local q; q="$(mktemp)"
    printf 'Research needs %s questions — over the cap of %s, which usually means the PRD is underspecified. Reply "override" to run all %s research agents anyway, or "return-to-align" to sharpen the PRD first.\n' \
      "$n" "$MAX_QUESTIONS" "$n" >"$q"
    write_pending "$q" "research"

    local first; first="$(head -1 "$q")"
    state_set_raw awaitingHuman true
    state_set_str pendingQuestion "$first"
    # In-flight stage label first (research), THEN the awaiting-human overlay.
    gh_relabel "lcars:research lcars:awaiting-human" "lcars:align"
    rm -f "$q"

    echo "GATE: too-many $n"
    echo "  Research wants $n questions — over the cap of $MAX_QUESTIONS. That"
    echo "  many open questions usually means the PRD is underspecified."
    echo "  Escalated to you (the card is now in Research, awaiting-human):"
    echo "    • override         — run all $n research agents anyway"
    echo "    • return-to-align  — re-run \`lcars file\` with this context appended"
    echo "                         so the PRD can be sharpened"
    echo "  Answer with \`lcars respond $MISSION_ID\`."
    [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
    exit 3
  fi

  echo "GATE: dispatch $n"
  echo "  Dispatching $n stateless research agent(s) — one per question."
  exit 0
}

# --- subcommand: save ------------------------------------------------------
cmd_save() {
  locate_mission "$MISSION_ID"
  require_stage align

  [ -n "$RESPONSES" ]   || die "no responses dir — pass --responses <dir>."
  [ -d "$RESPONSES" ]   || die "responses dir not found: $RESPONSES"

  local research_dir="$MISSION_DIR/research"
  mkdir -p "$research_dir"

  # Persist each response as research/<n>.json, renumbered 1..N in the input's
  # lexical order. Every response must carry the three required fields — a
  # malformed agent reply stops the save so we never advance on bad data.
  local n=0 f
  shopt -s nullglob
  for f in "$RESPONSES"/*.json; do
    grep -q '"question"'          "$f" || die "response $f is missing \"question\"."
    grep -q '"recommendation"'    "$f" || die "response $f is missing \"recommendation\"."
    grep -q '"supporting_points"' "$f" || die "response $f is missing \"supporting_points\"."
    n=$((n + 1))
    cp "$f" "$research_dir/$n.json"
  done
  shopt -u nullglob

  [ "$n" -gt 0 ] || die "no *.json responses in $RESPONSES — nothing to save."

  advance
  echo "SAVE: $n responses"
  echo "  Saved $n research response(s) to research/."
  echo "  Stage:  validate"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Validate stage ========================================================
# The Validator (Claude, per SKILL.md) reads prd.md + research/*.json and
# produces two things: a synthesis (validated-plan.md) and 0-N scope-change
# questions. The script handles the two mechanical outcomes:
#
#   validate-pause    --mission <id> --questions <file>
#         A finding implies a scope/direction change. Persist the questions to
#         pending.json, flip the Mission into the awaiting-human gate (state +
#         lcars:awaiting-human label), and stop. The card stays in Validate.
#
#   validate-advance  --mission <id> --plan <file>
#         No open scope question (or the human has since answered). Write the
#         synthesis to validated-plan.md, clear any awaiting-human gate, and
#         advance the Mission to Plan (stage + label validate → plan).

# --- write pending.json: the captain's scope-change questions ---------------
# One JSON string per non-blank line of the questions file, escaped. This is
# the queue `lcars respond` (a later build) reads to record the answers.
write_pending() { # questions-file  stage
  local pj="$MISSION_DIR/pending.json"
  {
    echo '{'
    printf '  "stage": "%s",\n' "$2"
    echo '  "questions": ['
    awk 'NF{ gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); q[++n]=$0 }
         END{ for(i=1;i<=n;i++) printf "    \"%s\"%s\n", q[i], (i<n?",":"") }' "$1"
    echo '  ]'
    echo '}'
  } >"$pj"
}

# --- subcommand: validate-pause --------------------------------------------
cmd_validate_pause() {
  locate_mission "$MISSION_ID"
  require_stage validate

  [ -n "$QFILE" ] && [ -f "$QFILE" ] || die "no questions file — pass --questions <file>."
  local n; n="$(grep -cve '^[[:space:]]*$' "$QFILE")"
  [ "$n" -gt 0 ] || die "no scope questions in $QFILE — use validate-advance when there are none."

  write_pending "$QFILE" "validate"

  # Mark the awaiting-human gate. pendingQuestion is what `lcars status` (the
  # board) prints, so surface the first question there; the full set lives in
  # pending.json.
  local first; first="$(grep -ve '^[[:space:]]*$' "$QFILE" | head -1)"
  state_set_raw awaitingHuman true
  state_set_str pendingQuestion "$first"

  # In-flight stage label first (validate — already applied on entry, re-asserted
  # so the escalation is self-contained), THEN the awaiting-human overlay, so the
  # paused card sits squarely in the Validate column.
  gh_relabel "lcars:validate lcars:awaiting-human" ""

  echo "VALIDATE: paused — $n scope question(s)"
  echo "  A finding implies a scope change. The Mission is waiting on you:"
  while IFS= read -r q; do
    [ -n "$q" ] && echo "    • $q"
  done < <(grep -ve '^[[:space:]]*$' "$QFILE")
  echo "  Stage:  validate (awaiting-human)"
  echo "  Answer with \`lcars respond $MISSION_ID\`."
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- subcommand: validate-advance ------------------------------------------
cmd_validate_advance() {
  locate_mission "$MISSION_ID"
  require_stage validate

  [ -n "$PLAN" ] && [ -f "$PLAN" ] || die "no plan file — pass --plan <file>."

  # The synthesis must carry its required sections — same contract as the PRD
  # (file.sh) and research responses (save): a malformed plan stops the advance
  # so we never move on with a half-formed plan.
  grep -q '^# Validated Plan'  "$PLAN" || die "plan is missing its '# Validated Plan' title."
  grep -q '^## Synthesis'      "$PLAN" || die "plan is missing the '## Synthesis' section."
  grep -q '^## Decisions'      "$PLAN" || die "plan is missing the '## Decisions' section."
  # The artifact is the only thing crossing the stage boundary, so it must carry
  # the WHY, not just the WHAT — a decision without its rationale is how the next
  # stage builds the wrong thing (vision.md → Stage Isolation). Refuse a plan
  # that records decisions but drops their reasoning.
  grep -q '^## Rationale'      "$PLAN" || die "plan is missing the '## Rationale' section — record the WHY behind the decisions, not just the decisions."

  cp "$PLAN" "$MISSION_DIR/validated-plan.md"

  # Resume cleanly whether or not we ever paused: clear the awaiting-human gate
  # (state fields, pending.json) and consume any answer `lcars respond` left —
  # all no-ops on the straight-through path. Folding the answer into the
  # synthesis is Claude's job (per SKILL.md); deleting answers.json here is what
  # makes the resume one-shot, so the stage never re-asks.
  state_del awaitingHuman
  state_del pendingQuestion
  rm -f "$MISSION_DIR/pending.json" "$MISSION_DIR/answers.json"

  set_stage "plan"
  gh_relabel "lcars:plan" "lcars:validate lcars:awaiting-human"

  echo "VALIDATE: advanced"
  echo "  Wrote validated-plan.md."
  echo "  Stage:  plan"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Plan stage ============================================================
# The Planning LLM (Claude, per SKILL.md) reads prd.md + validated-plan.md and
# decomposes the plan into a list of small, vertical-slice tickets. It writes
# the whole list as plan.json (a JSON array) to a temp file and hands it here:
#
#   plan-save  --mission <id> --plan <file>
#         Validate the ticket list, install it as plan.json, and advance the
#         Mission to Plan Review (stage + label plan → plan-review).
#
# plan.json is a JSON array of ticket objects in a canonical one-field-per-line
# shape (acceptanceCriteria / dependencies are inline single-line arrays), so
# the validator below can stay line-oriented and jq-free — same spirit as the
# other readers in this file.

# --- validate the ticket list ----------------------------------------------
# Enforces the plan.json contract so we never advance on a half-formed plan,
# mirroring how `save` guards research responses and `validate-advance` guards
# the synthesis. Pure awk over the canonical one-field-per-line shape (inline
# acceptanceCriteria / dependencies arrays), so it stays jq-free. Each ticket
# must carry every required field, at least one acceptance criterion, and only
# depend on ticket ids that exist in this same plan. Prints the first failure
# and returns non-zero; silent on success.
validate_plan_json() { # file
  awk '
    function fail(msg) { printf "lcars run: %s\n", msg > "/dev/stderr"; exit 1 }
    # object boundaries — canonical format puts { and } on their own lines, and
    # the only braces in the file are object delimiters (arrays are inline).
    /^[[:space:]]*\{[[:space:]]*$/ {
      inobj=1; delete have; acok=0; id=""; ndep=0; next
    }
    /^[[:space:]]*\}[,]?[[:space:]]*$/ {
      if (!inobj) next
      tickets++
      for (k=1; k<=9; k++) if (!have[req[k]]) fail("ticket " tickets " is missing \"" req[k] "\".")
      if (!acok) fail("ticket " tickets " (" id ") needs at least one acceptance criterion.")
      ids[id]=1
      for (d=1; d<=ndep; d++) { depof[++drefs]=dep[d]; depticket[drefs]=id }
      inobj=0; next
    }
    inobj {
      n=split($0, a, "\"")          # inside-quote contents land at even indices
      if (n < 2) next
      key=a[2]; have[key]=1
      if (key=="id") id=a[4]
      else if (key=="acceptanceCriteria") { if (n >= 4) acok=1 }
      else if (key=="dependencies") { for (i=4; i<=n; i+=2) if (a[i] != "") dep[++ndep]=a[i] }
    }
    # DESIGN NOTE (Session 31): the three estimate fields are a SHAPE contract,
    # not a SIZE policy. We require all three to be present, but we deliberately
    # do NOT reject a ticket whose read+test+new exceeds comprehensionBudget —
    # the budget is a PLANNING TARGET, not a deterministic reject. A single large
    # existing file can force estimatedReadLoc alone over budget; that load is
    # UNAVOIDABLE and must not deadlock planning. The size judgement ("over
    # budget because it BUNDLES behaviors" vs "over budget because the file is
    # just big") lives in the Plan prompt + Plan Review, never here.
    BEGIN { req[1]="id"; req[2]="title"; req[3]="description";
            req[4]="acceptanceCriteria"; req[5]="estimatedReadLoc";
            req[6]="estimatedTestLoc"; req[7]="estimatedNewLoc";
            req[8]="dependencies"; req[9]="rationale" }
    END {
      if (tickets == 0) fail("no tickets in the plan — a plan needs at least one ticket.")
      for (r=1; r<=drefs; r++)
        if (!(depof[r] in ids))
          fail("ticket " depticket[r] " depends on \"" depof[r] "\", which is not a ticket id in this plan.")
    }
  ' "$1"
}

# --- subcommand: plan-save -------------------------------------------------
cmd_plan_save() {
  locate_mission "$MISSION_ID"
  require_stage plan

  [ -n "$PLAN" ] && [ -f "$PLAN" ] || die "no plan file — pass --plan <file>."

  validate_plan_json "$PLAN" || exit 1

  cp "$PLAN" "$MISSION_DIR/plan.json"

  set_stage "plan-review"
  gh_relabel "lcars:plan-review" "lcars:plan"

  echo "PLAN: advanced"
  echo "  Wrote plan.json."
  echo "  Stage:  plan-review"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Plan Review stage =====================================================
# A FRESH reviewer session (Claude, per SKILL.md) audits plan.json — and ONLY
# plan.json, never prd.md or validated-plan.md — against the fixed quality bar
# (vertical slice, <300 LoC, testable, deps in-plan) and emits a verdict:
#
#   { "passed": <bool>, "issues": [ { "ticketId": "...", "objection": "..." } ] }
#
# It hands that verdict to the one mechanical subcommand, which branches on it:
#
#   review-save  --mission <id> --verdict <file>
#         passed=true  → write approved-plan.json, advance to Schedule.
#         passed=false → log the round's objections to plan-review-<round>.json,
#                        bump planReviewRound, and loop the Mission back to Plan
#                        for revision — UNTIL the 3rd round, which escalates to
#                        the human (awaiting-human gate, card stays in Plan
#                        Review) instead of looping forever.
#
# The reviewer's independence from the planner is deliberate (see vision.md →
# Plan Review): the session that planned the work must not also grade it, so it
# is given the tickets alone, not the spec that produced them.

# --- approve: copy plan.json → approved-plan.json, advance to schedule -------
review_pass() {
  [ -f "$MISSION_DIR/plan.json" ] || die "no plan.json to approve — has Plan run?"
  cp "$MISSION_DIR/plan.json" "$MISSION_DIR/approved-plan.json"

  set_stage "schedule"
  gh_relabel "lcars:schedule" "lcars:plan-review"

  echo "PLAN-REVIEW: passed"
  echo "  Every ticket cleared review. Wrote approved-plan.json."
  echo "  Stage:  schedule"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- print the verdict's objections, one bulleted "<ticket> — <objection>" --
# Canonical one-issue-per-line shape means splitting on " lands the ticketId at
# field 4 and the objection text at field 8 (same jq-free spirit as the rest).
print_objections() { # verdict-file  prefix
  awk -F'"' -v p="$2" '/"objection"/ { printf "%s%s — %s\n", p, $4, $8 }' "$1"
}

# --- fail: log this round, then loop back to Plan or escalate at round 3 -----
review_fail() {
  grep -q '"objection"' "$VERDICT" \
    || die "verdict says failed but lists no issues — a failing review must name its objections."

  local round; round="$(json_raw "$STATE" planReviewRound)"; round="${round:-0}"
  round=$((round + 1))

  # Log the full verdict for this round so the planner (and the human, on
  # escalation) can see exactly what was objected to.
  cp "$VERDICT" "$MISSION_DIR/plan-review-$round.json"
  state_set_raw planReviewRound "$round"

  if [ "$round" -ge "$MAX_REVIEW_ROUNDS" ]; then
    # Out of rounds — hand the unresolved issues to the human. The card stays in
    # the Plan Review column with the awaiting-human overlay (same gate shape as
    # validate-pause), so it reads as "in Plan Review, awaiting me".
    local obj; obj="$(mktemp)"
    print_objections "$VERDICT" "" >"$obj"
    write_pending "$obj" "plan-review"

    local first; first="$(head -1 "$obj")"
    state_set_raw awaitingHuman true
    state_set_str pendingQuestion "$first"
    gh_relabel "lcars:awaiting-human" ""

    echo "PLAN-REVIEW: escalated — $round rounds without a clean plan"
    echo "  Plan Review could not reach a clean plan after $round rounds. Unresolved:"
    print_objections "$VERDICT" "    • "
    echo "  Stage:  plan-review (awaiting-human)"
    echo "  Override (proceed to Schedule) or redirect — answer with \`lcars respond $MISSION_ID\`."
    [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
    exit 0
  fi

  # Still have rounds left — bounce the Mission back to Plan to revise.
  set_stage "plan"
  gh_relabel "lcars:plan" "lcars:plan-review"

  echo "PLAN-REVIEW: revise — round $round"
  echo "  Tickets did not pass review. Logged objections to plan-review-$round.json:"
  print_objections "$VERDICT" "    • "
  echo "  Stage:  plan (revise the tickets and re-run)"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- subcommand: review-save -----------------------------------------------
cmd_review_save() {
  locate_mission "$MISSION_ID"
  require_stage plan-review

  [ -n "$VERDICT" ] && [ -f "$VERDICT" ] || die "no verdict file — pass --verdict <file>."

  case "$(json_raw "$VERDICT" passed)" in
    true)  review_pass ;;
    false) review_fail ;;
    *)     die "verdict is missing a boolean \"passed\" field." ;;
  esac
}

# === Schedule stage ========================================================
# Purely mechanical — no LLM. Reads approved-plan.json, builds the dependency
# graph, groups tickets into sequential waves (tickets within a wave are
# mutually independent and so implementable in parallel), opens one GitHub
# sub-issue per ticket, records the new issue numbers, and advances the Mission
# to Implement:
#
#   schedule  --mission <id>
#
# A wave N holds every not-yet-placed ticket whose dependencies all sit in
# waves < N (Kahn's algorithm, layered). If a round can place no ticket while
# tickets remain, the graph has a cycle — the script names the stuck tickets and
# changes nothing (no waves.json, no issues, no stage move). On success it writes
# waves.json — [ { wave, tickets:[ { id, issue } ] } ] — and moves the stage +
# label schedule → implement, keeping the on-disk stage and the board in step.

# --- parse approved-plan.json into a tab-separated ticket table -------------
# One line per ticket: id \t title \t description \t criteria \t deps
# criteria items are joined with " | " and deps with spaces — both are inline
# single-line arrays in the canonical shape, so no field ever spans lines. Same
# jq-free, line-oriented parse as validate_plan_json.
parse_plan_table() { # file
  awk '
    function flush() {
      if (id=="") return
      printf "%s\t%s\t%s\t%s\t%s\n", id, title, desc, crit, deps
    }
    /^[[:space:]]*\{[[:space:]]*$/ { inobj=1; id=""; title=""; desc=""; crit=""; deps=""; next }
    /^[[:space:]]*\}[,]?[[:space:]]*$/ { if (inobj) flush(); inobj=0; next }
    inobj {
      n=split($0, a, "\"")             # inside-quote contents land at even indices
      if (n < 2) next
      key=a[2]
      if (key=="id") id=a[4]
      else if (key=="title") title=a[4]
      else if (key=="description") desc=a[4]
      else if (key=="acceptanceCriteria") { c=""; for (i=4;i<n;i+=2) if (a[i]!="") c=(c==""?a[i]:c" | "a[i]); crit=c }
      else if (key=="dependencies")       { d=""; for (i=4;i<n;i+=2) if (a[i]!="") d=(d==""?a[i]:d" "a[i]); deps=d }
    }
  ' "$1"
}

# --- group tickets into waves; detect cycles --------------------------------
# Reads the ticket table (id in field 1, deps in field 5) and prints one line
# per wave: "<wave-number> <id> <id> …", tickets in plan order. On a cycle — a
# round that can place no ticket while some remain — prints a clear error naming
# the stuck tickets to stderr and exits non-zero, so the caller changes nothing.
compute_waves() { # table-file
  awk -F'\t' '
    { order[++count]=$1; depstr[$1]=$5 }
    END {
      for (k=1;k<=count;k++) {
        id=order[k]; nd=split(depstr[id], dd, " "); ndep[id]=0
        for (j=1;j<=nd;j++) if (dd[j]!="") { ndep[id]++; dep[id, ndep[id]]=dd[j] }
      }
      placed=0; wave=0
      while (placed < count) {
        wave++; wc=0
        for (k=1;k<=count;k++) {
          id=order[k]
          if (done[id]) continue
          ready=1
          for (i=1;i<=ndep[id];i++) if (!done[dep[id,i]]) { ready=0; break }
          if (ready) ready_id[++wc]=id
        }
        if (wc==0) {
          msg="lcars run: circular dependency detected among the remaining tickets:"
          for (k=1;k<=count;k++) if (!done[order[k]]) msg=msg " " order[k]
          print msg > "/dev/stderr"
          exit 2
        }
        line=wave
        for (i=1;i<=wc;i++) line=line " " ready_id[i]
        print line
        for (i=1;i<=wc;i++) { done[ready_id[i]]=1; placed++ }
      }
    }
  ' "$1"
}

# --- create one GitHub sub-issue for a ticket; echo its new issue number -----
# Best-effort, same spirit as gh_relabel: if gh is missing or the create fails,
# leave a note and echo nothing (the wave entry records a null issue). gh prints
# the new issue's URL on stdout, so we keep the trailing path segment (the
# number). The body carries the description and the acceptance criteria as a
# bulleted list.
create_issue() { # id  type  table-file
  local id="$1" type="$2" table="$3" line title desc crit critblock body url
  line="$(awk -F'\t' -v want="$id" '$1==want{print; exit}' "$table")"
  title="$(printf '%s' "$line" | cut -f2)"
  desc="$(printf '%s' "$line" | cut -f3)"
  crit="$(printf '%s' "$line" | cut -f4)"

  critblock=""
  [ -n "$crit" ] && critblock="$(printf '%s' "$crit" | awk -F' \\| ' '{ for (i=1;i<=NF;i++) printf "- %s\n", $i }')"
  body="$(printf '%s\n\n**Acceptance Criteria:**\n%s' "$desc" "$critblock")"

  # Delegate the forge call to the adapter; it echoes the new issue NUMBER (or
  # nothing on failure / no gh). The caller still owns the label string — the
  # adapter just forwards the labels it is given.
  local num
  num="$(host issue-create --title "$title" --body "$body" --label "lcars:implement,lcars:$type,lcars:ticket")"
  if [ -n "$num" ]; then
    printf '%s' "$num"
    return 0
  fi
  RELABEL_NOTE="  ⚠ could not create sub-issues via gh — create them by hand and add lcars:implement."
  return 0
}

# --- render waves.json from the wave/id/issue assignments --------------------
# Input lines: "<wave>\t<id>\t<issue>" in wave then plan order. Emits the
# canonical waves.json — an array of { wave, tickets:[ { id, issue } ] }.
emit_waves_json() { # assignments-file
  awk -F'\t' '
    { w=$1; if (!(w in seen)) { seen[w]=1; worder[++nw]=w }
      cnt[w]++; tid[w, cnt[w]]=$2; tiss[w, cnt[w]]=$3 }
    END {
      print "["
      for (x=1;x<=nw;x++) {
        w=worder[x]
        print "  {"
        printf "    \"wave\": %s,\n", w
        print "    \"tickets\": ["
        for (y=1;y<=cnt[w];y++) {
          print "      {"
          printf "        \"id\": \"%s\",\n", tid[w,y]
          printf "        \"issue\": %s\n", (tiss[w,y]==""?"null":tiss[w,y])
          printf "      }%s\n", (y<cnt[w]?",":"")
        }
        print "    ]"
        printf "  }%s\n", (x<nw?",":"")
      }
      print "]"
    }
  ' "$1"
}

# --- subcommand: schedule ---------------------------------------------------
cmd_schedule() {
  locate_mission "$MISSION_ID"
  require_stage schedule

  local plan="$MISSION_DIR/approved-plan.json"
  [ -f "$plan" ] || die "no approved-plan.json — Plan Review has not approved a plan yet."

  local type; type="$(json_str "$STATE" type)"; type="${type:-feature}"

  local table; table="$(mktemp)"
  parse_plan_table "$plan" >"$table"
  [ -s "$table" ] || { rm -f "$table"; die "approved-plan.json has no tickets — nothing to schedule."; }

  # Build the waves first; a cycle stops us before any issue is created or any
  # state changes (compute_waves has already named the stuck tickets).
  local wavemap; wavemap="$(mktemp)"
  if ! compute_waves "$table" >"$wavemap"; then
    rm -f "$table" "$wavemap"
    exit 1
  fi

  # SINGLE-TICKET FAST-PATH (BUG-005, Session 33). When Plan emits exactly ONE
  # ticket, a per-ticket sub-issue would merely DUPLICATE the Mission's own
  # issue — so don't open one. Reuse the Mission's githubIssue as the lone
  # ticket's issue and emit a one-wave waves.json directly. The on-green close
  # in cmd_impl_save_result has a matching guard so this reused parent issue is
  # NOT closed on green (it closes on PR merge, in lcars-approve). Ticket count
  # is the number of rows in $table (one row per ticket).
  local assign; assign="$(mktemp)"
  local nwaves=0 ntickets=0 nissues=0 wnum ids id num
  local ticket_count; ticket_count="$(grep -c . "$table")"
  if [ "$ticket_count" -le 1 ]; then
    # The lone ticket id is the single row's first field; its wave is whatever
    # compute_waves placed it in (always 1 with ≤1 ticket, but read it rather
    # than assume).
    local lone_id lone_wave parent
    lone_id="$(awk -F'\t' 'NF{print $1; exit}' "$table")"
    lone_wave="$(awk 'NF{print $1; exit}' "$wavemap")"; lone_wave="${lone_wave:-1}"
    parent="$(json_raw "$STATE" githubIssue)"
    nwaves=1; ntickets=1
    case "$parent" in
      ''|null)
        # Degraded path: no issue on file. Keep TODAY's behaviour — issue: null
        # plus the existing warning. NEVER fabricate an issue; the fast-path is
        # about not creating a REDUNDANT one, never about inventing one.
        printf '%s\t%s\t%s\n' "$lone_wave" "$lone_id" "" >>"$assign"
        RELABEL_NOTE="  ⚠ no githubIssue on file — wrote issue: null for $lone_id (local-only mission)."
        ;;
      *)
        # Reuse the Mission's own issue; open NO sub-issue (nissues stays 0).
        printf '%s\t%s\t%s\n' "$lone_wave" "$lone_id" "$parent" >>"$assign"
        ;;
    esac
  else
    # ≥ 2 tickets. One sub-issue per ticket, in wave then plan order; record
    # wave/id/issue. AND (Session 35) nest each fresh ticket issue under the
    # Mission's own issue as a NATIVE GitHub sub-issue, so the board shows the
    # ticket hierarchy. Read the Mission's parent issue once up front.
    local parent link_failed=0
    parent="$(json_raw "$STATE" githubIssue)"
    while read -r wnum ids; do
      [ -n "$wnum" ] || continue
      nwaves=$((nwaves + 1))
      for id in $ids; do
        ntickets=$((ntickets + 1))
        num="$(create_issue "$id" "$type" "$table")"
        [ -n "$num" ] && nissues=$((nissues + 1))
        printf '%s\t%s\t%s\n' "$wnum" "$id" "$num" >>"$assign"
        # Nest the new child under the Mission — best-effort, ENTIRELY through
        # the host adapter (no direct gh/REST here) so it stays host-agnostic.
        # Guards: skip a child we failed to create (empty num); skip when there
        # is no parent on file; and EXPLICITLY skip when child == parent (the
        # single-ticket fast-path reuses the Mission issue as the lone ticket's
        # issue, which would self-nest #parent under #parent). A link failure
        # NEVER aborts Schedule — it only sets a "nest by hand" note.
        case "$parent" in ''|null) parent="" ;; esac
        if [ -n "$num" ] && [ -n "$parent" ] && [ "$num" != "$parent" ]; then
          host link-subissue "$parent" "$num" || link_failed=1
        fi
      done
    done <"$wavemap"
    [ "$link_failed" -eq 1 ] && RELABEL_NOTE="  ⚠ could not nest sub-issue(s) under the Mission — link them by hand."
  fi

  emit_waves_json "$assign" >"$MISSION_DIR/waves.json"

  set_stage "implement"
  gh_relabel "lcars:implement" "lcars:schedule"

  rm -f "$table" "$wavemap" "$assign"

  echo "SCHEDULE: advanced"
  echo "  Grouped $ntickets ticket(s) into $nwaves wave(s); opened $nissues sub-issue(s)."
  echo "  Wrote waves.json."
  echo "  Stage:  implement"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Implement stage =======================================================
# Processes the waves from waves.json sequentially; tickets within a wave run in
# parallel. Each ticket is built by two adversarially-separated LLM sessions
# (Claude, per SKILL.md): a Test Writer (Phase 1) writes failing tests, then a
# FRESH Implementer (Phase 2 — no Test Writer context) makes them pass, iterating
# up to 5 attempts. This script owns the mechanical, testable handoffs:
#
#   impl-save-tests   --mission <id> --ticket <id> --tests <dir>
#         Phase 1 output. Quarantine the Test Writer's files into
#         tickets/<id>/tests/ — that dir is the ONLY channel to the Implementer,
#         so the separation stays adversarial. Refuses an empty set.
#
#   impl-save-result  --mission <id> --ticket <id> --result <file>
#         Phase 2 output. Validate { ticketId, passed, attempts, summary },
#         cap attempts at 5, and persist tickets/<id>/result.json. A passed=false
#         result means the Implementer exhausted its 5 attempts — flag the human.
#
#   impl-status       --mission <id>
#         Read-only. Report the current wave (the lowest wave with an unfinished
#         ticket) and its still-pending tickets. Never reveals a later wave while
#         an earlier one is incomplete — that's the sequential-wave gate.
#
#   impl-advance      --mission <id>
#         When every ticket in every wave has a passing result, advance the
#         Mission to Verify (stage + label implement → verify). Refuses while any
#         ticket is unfinished.

MAX_ATTEMPTS=5
COMMIT_NOTE=""

# --- resolve a ticket's working dir under the mission -----------------------
ticket_dir() { printf '%s/tickets/%s' "$MISSION_DIR" "$1"; }

# --- snapshot the working tree's untracked files ----------------------------
# Records the captain's PRE-EXISTING untracked files (taken before any worker
# runs for a ticket) so commit_ticket can tell the Implementer's NEW source from
# files that were already lying around (bugs.md, lockfiles, …). Best-effort and
# jq-free; an empty/failed snapshot just means "nothing was pre-existing".
snapshot_untracked() { # out-file
  ( cd "$REPO_ROOT" && "$GIT_BIN" ls-files --others --exclude-standard ) >"$1" 2>/dev/null || : >"$1"
}

# === Scratch hygiene (CLI/host-agnostic) ====================================
# ONE place defines what counts as throwaway scratch the harness must never let
# into a Mission's PR. It is NOT hardcoded to one agentic CLI: it covers LCARS's
# own scratch, a harness-OWNED worker-runner prefix, and the scratch dirs each
# common CLI drops in a repo (Claude's `.claude/`, Copilot's `.copilot/`). The
# captain extends it without code via config.json `scratchGlobs` (a JSON string
# array) — so a new CLI or a project-specific runner is one config line, never a
# code change. These globs are matched with shell `case` against paths from
# `git ls-files --others` AND written verbatim into `.git/info/exclude`.

# --- the harness-owned worker-runner prefix ---------------------------------
# A repo-write worker (the Implementer) may need a throwaway runner file in the
# tree (e.g. to invoke the suite). The harness OWNS one neutral, CLI-agnostic
# name for it — `.lcars-run-*` — so the driver can both refuse to commit it and
# DELETE it afterwards without guessing per-CLI names. The implement-implementer
# prompt steers workers to this name (and to LCARS_WORK_OUT for runners). The
# `.lcars-*` family already covers it; this constant names it for cleanup.
LCARS_RUNNER_GLOB='.lcars-run-*'

# --- the full scratch glob set (base + config extensions) -------------------
# Emits one glob per line. Base set is CLI/host-agnostic; config.json's
# `scratchGlobs` array (read jq-free) appends to it. Dir globs are listed both as
# `<dir>/` (the exclude-file form) and `<dir>/*` (so a `case` match catches every
# path under them). Deduped, stable order, base first.
scratch_globs() {
  printf '%s\n' \
    '.lcars-*' '*/.lcars-*' \
    '.lcars-run-*' '*/.lcars-run-*' \
    '.claude/' '.claude/*' '*/.claude/*' \
    '.copilot/' '.copilot/*' '*/.copilot/*' \
    '.*-run.cjs' '.*-run.mjs' '.*-run.js' '.*-run.sh' '.*-run.py' \
    '*/.*-run.cjs' '*/.*-run.mjs' '*/.*-run.js' '*/.*-run.sh' '*/.*-run.py'
  # config extensions: pull every quoted token out of the scratchGlobs array.
  [ -n "${LCARS_CFG:-}" ] && [ -f "$LCARS_CFG" ] || return 0
  awk '
    /"scratchGlobs"[[:space:]]*:/ { ina=1 }
    ina {
      s=$0
      while (match(s, /"[^"]*"/)) {
        tok=substr(s, RSTART+1, RLENGTH-2)
        if (tok != "scratchGlobs") print tok
        s=substr(s, RSTART+RLENGTH)
      }
      if (index($0, "]")) ina=0
    }
  ' "$LCARS_CFG" 2>/dev/null
}

# --- does a path match the scratch set? -------------------------------------
# jq-free, glob via `case`. Used by commit_ticket to skip scratch when staging.
is_scratch() { # path
  local p="$1" g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254
    case "$p" in $g) return 0 ;; esac
  done <<EOF
$(scratch_globs)
EOF
  return 1
}

# --- ignore scratch via .git/info/exclude (NEVER the tracked .gitignore) ----
# vision.md forbids editing a target repo's tracked .gitignore. .git/info/exclude
# lives inside .git/ (like .git/lcars/) and git never tracks it, so the captain's
# working tree and history stay clean while scratch is kept out of `git status`
# and any future `git add`. IDEMPOTENT: a glob already present is never appended
# again. Best-effort; a missing .git/info dir is created.
ensure_scratch_excluded() {
  local gitdir excl g
  gitdir="$("$GIT_BIN" rev-parse --git-dir 2>/dev/null)" || return 0
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  mkdir -p "$gitdir/info" 2>/dev/null || return 0
  excl="$gitdir/info/exclude"
  [ -f "$excl" ] || : >"$excl"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    grep -qxF -- "$g" "$excl" 2>/dev/null || printf '%s\n' "$g" >>"$excl"
  done <<EOF
$(scratch_globs)
EOF
}

# --- commit a green ticket's produced files to the mission branch -----------
# The Test Writer / Implementer write real files into the working tree; for the
# PR to have content those files must be committed to the Mission's branch (the
# one `lcars file` recorded in state.json). On the first green ticket this also
# checks the branch out — Implement is the first stage that touches git, and the
# captain's working tree was left untouched up to here, so any uncommitted work
# follows the checkout onto the branch and is captured. Best-effort and jq-free,
# in the same spirit as gh_relabel: a missing branch / no changes / git failure
# leaves a note rather than blocking the (already-saved) result.
commit_ticket() { # ticket  summary
  COMMIT_NOTE=""
  local branch; branch="$(json_str "$STATE" branch)"
  [ -n "$branch" ] || { COMMIT_NOTE="  ⚠ no mission branch on file — skipped commit (re-file so the mission gets a branch)."; return 0; }

  local cur; cur="$("$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$cur" != "$branch" ]; then
    if "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
      "$GIT_BIN" checkout "$branch" >/dev/null 2>&1 \
        || { COMMIT_NOTE="  ⚠ could not checkout $branch — commit ticket $1 by hand."; return 0; }
    else
      "$GIT_BIN" checkout -b "$branch" >/dev/null 2>&1 \
        || { COMMIT_NOTE="  ⚠ could not create $branch — commit ticket $1 by hand."; return 0; }
    fi
  fi

  # Belt-and-braces: ensure the scratch globs are in .git/info/exclude before we
  # stage, so even a future `git add`/`status` ignores them (idempotent; `lcars
  # init` does this too, but a mission created without init — e.g. via `lcars log`
  # — still gets the guard on its first commit). Never touches the .gitignore.
  ensure_scratch_excluded

  # Stage the Implementer's work, SCOPED — never the whole tree (no `git add -A`,
  # which would sweep in the captain's unrelated untracked files and the worker's
  # throwaway scratch). Edits to already-tracked files go in via `add -u`; a NEW
  # file is staged only when it did NOT exist before the ticket built (the
  # .untracked-before snapshot) and is not harness/CLI scratch (see is_scratch —
  # the CLI/host-agnostic set: `.lcars-*`, the harness runner prefix, each CLI's
  # scratch dir, plus config.json `scratchGlobs`). That keeps the mission branch
  # / PR to the produced source.
  "$GIT_BIN" add -u >/dev/null 2>&1
  local before; before="$(ticket_dir "$1")/.untracked-before"
  local now f; now="$(mktemp)"
  ( cd "$REPO_ROOT" && "$GIT_BIN" ls-files --others --exclude-standard ) >"$now" 2>/dev/null
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_scratch "$f" && continue                                     # harness/CLI scratch
    [ -f "$before" ] && grep -qxF -- "$f" "$before" && continue     # pre-existing untracked
    ( cd "$REPO_ROOT" && "$GIT_BIN" add -- "$f" >/dev/null 2>&1 )
  done <"$now"
  rm -f "$now"

  if "$GIT_BIN" diff --cached --quiet 2>/dev/null; then
    COMMIT_NOTE="  ⚠ ticket $1 produced no file changes to commit."
    cleanup_runner_scratch "$before"
    return 0
  fi
  "$GIT_BIN" commit -q -m "lcars($MISSION_ID) $1: $2" >/dev/null 2>&1 \
    || COMMIT_NOTE="  ⚠ git commit failed for ticket $1 — commit it by hand."
  # After the ticket commits, sweep the HARNESS-OWNED runner scratch from the
  # tree so it never lingers into later tickets or the captain's `git status`.
  # ONLY the harness's own `.lcars-run-*` files, and never a file the captain had
  # before the ticket (the .untracked-before snapshot) or worker output under
  # .git/lcars — so the captain's work is never destroyed.
  cleanup_runner_scratch "$before"
}

# --- remove the harness-owned runner scratch from the working tree ----------
# Deletes ONLY `.lcars-run-*` files the harness controls, and ONLY when they were
# NOT pre-existing (absent from the .untracked-before snapshot). Uses `git
# ls-files --others` WITHOUT --exclude-standard on purpose: once
# ensure_scratch_excluded has hidden the runner via .git/info/exclude, the
# excluded listing no longer shows it, but we still must delete it. The bare
# --others listing skips .git/ for us, so worker output under .git/lcars is never
# touched. jq-free, best-effort; the captain's files are spared by the snapshot.
cleanup_runner_scratch() { # before-snapshot
  local before="$1" f
  ( cd "$REPO_ROOT" && "$GIT_BIN" ls-files --others ) 2>/dev/null \
  | while IFS= read -r f; do
      [ -n "$f" ] || continue
      # shellcheck disable=SC2254
      case "$f" in $LCARS_RUNNER_GLOB|*/$LCARS_RUNNER_GLOB) : ;; *) continue ;; esac
      [ -f "$before" ] && grep -qxF -- "$f" "$before" && continue   # captain's — keep
      rm -f "$REPO_ROOT/$f" 2>/dev/null || :
    done
}

# --- parse waves.json into "<wave>\t<id>" lines, in wave then plan order ------
# Canonical waves.json (emit_waves_json's shape) puts "wave": N and each ticket's
# "id" on their own lines, so a line-oriented awk pass is enough — same jq-free
# spirit as parse_plan_table. The wave number leads each ticket so callers can
# group and sequence without re-reading the file.
parse_waves_table() { # waves.json
  awk '
    /"wave"[[:space:]]*:/ { w=$0; gsub(/[^0-9]/,"",w); cur=w; next }
    /"id"[[:space:]]*:/   { n=split($0,a,"\""); if (n>=4) printf "%s\t%s\n", cur, a[4] }
  ' "$1"
}

# --- a ticket's sub-issue number from waves.json ----------------------------
# Canonical waves.json pairs each ticket's "id" line with its "issue" line right
# below (emit_waves_json's shape). A line-oriented awk pass tracks the current id
# and, on the matching ticket, echoes the issue token — a number, or "null" for a
# local-only mission (no sub-issue was created). Empty output = id not found.
# This is the ticket→sub-issue map Rule A reads to close the right issue.
ticket_issue() { # waves.json  ticketId
  awk -v want="$2" '
    /"id"[[:space:]]*:/    { n=split($0,a,"\""); if (n>=4) cur=a[4]; next }
    /"issue"[[:space:]]*:/ { if (cur==want) {
        v=$0; sub(/.*"issue"[[:space:]]*:[[:space:]]*/,"",v); gsub(/[ ,}]/,"",v)
        print v; exit } }
  ' "$1"
}

# --- is a ticket green? (result.json exists with passed:true) ----------------
ticket_green() { # ticketId
  local rf; rf="$(ticket_dir "$1")/result.json"
  [ -f "$rf" ] || return 1
  [ "$(json_raw "$rf" passed)" = "true" ]
}

# === Implement guardrails (deterministic — enforced by the harness, not the LLM) ==
# The adversarial Test Writer → Implementer split would otherwise rest on prompt
# instructions alone, and an LLM rewarded for a green suite games that contract.
# These three checks live HERE, in the driver, so a worker can't talk its way
# around them: a red gate (the tests must fail first), an immutability snapshot
# (the tests can't be edited to pass), and a quality check (the tests must assert
# something). See vision.md → Implement.

# --- resolve the test command (env wins, then repo config) ------------------
resolve_test_cmd() {
  if [ -n "$TEST_CMD_ENV" ]; then printf '%s' "$TEST_CMD_ENV"; return 0; fi
  [ -f "$LCARS_CFG" ] || return 0
  local c; c="$(json_str "$LCARS_CFG" testCommand)"
  case "$c" in ''|null) return 0 ;; esac
  printf '%s' "$c"
}

# --- GUARDRAIL 1: the red gate ----------------------------------------------
# Run the configured test command against the just-written tests with NO
# implementation present. Returns 0 when it is SAFE to hand the suite to the
# Implementer (the suite FAILED — red — as it must, OR no runner is configured so
# the gate cannot apply); returns non-zero when the suite PASSED green against
# nothing, which means it proves nothing and must be rejected. The command runs
# from the repo root with $LCARS_TESTS_DIR pointing at the quarantined tests, so
# a real per-repo runner (or a test stub) can find them without re-parsing args.
red_gate_ok() { # quarantined-tests-dir
  local tdir="$1" cmd rc=0
  cmd="$(resolve_test_cmd)"
  if [ -z "$cmd" ]; then
    printf '  ⚠ RED GATE SKIPPED — no test command (set `testCommand` in .git/lcars/config.json or $LCARS_TEST_CMD). The harness cannot prove the suite fails without an implementation.\n' >&2
    return 0
  fi
  ( cd "$REPO_ROOT" && LCARS_TESTS_DIR="$tdir" bash -c "$cmd" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ]   # non-zero = red = OK; zero = green-on-nothing = reject
}

# --- GUARDRAIL 2: immutable tests (hash snapshot + verify) ------------------
sha_of() { # file → hex digest
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else die "no sha256 tool (shasum / sha256sum) available for the immutable-tests guardrail."; fi
}
# Write "<hash>  <relpath>" for every file under a tests dir, in stable order.
snapshot_tests() { # tests-dir  out-file
  local d="$1" out="$2" rel
  : >"$out"
  while IFS= read -r rel; do
    rel="${rel#./}"
    printf '%s  %s\n' "$(sha_of "$d/$rel")" "$rel" >>"$out"
  done < <(cd "$d" && find . -type f | LC_ALL=C sort)
}
# 0 if the ticket's quarantined tests still match the snapshot taken at
# impl-save-tests; non-zero if any test file was added, removed, or changed.
tests_unchanged() { # ticketId
  local tdir snap cur
  tdir="$(ticket_dir "$1")/tests"; snap="$(ticket_dir "$1")/tests.sha256"
  [ -f "$snap" ] || return 1   # no snapshot → cannot prove unchanged → treat as a violation
  cur="$(mktemp)"; snapshot_tests "$tdir" "$cur"
  if diff -q "$snap" "$cur" >/dev/null 2>&1; then rm -f "$cur"; return 0; fi
  rm -f "$cur"; return 1
}

# --- GUARDRAIL 3: test quality (the suite must assert something) ------------
# Light, language-agnostic: reject a suite where no file contains any common
# assertion construct — an empty / zero-assertion / sandbagged contract proves
# nothing. The red gate catches a trivially-PASSING suite; this catches one that
# asserts nothing at all.
suite_has_assertions() { # tests-dir
  grep -rEiq 'assert|expect|should|\.to[A-Za-z]|require\(|t\.(is|deep|truthy|throws)|check\(|verify\(' "$1" 2>/dev/null
}

# --- subcommand: impl-save-tests -------------------------------------------
cmd_impl_save_tests() {
  locate_mission "$MISSION_ID"
  require_stage implement
  [ -n "$TICKET" ] || die "no ticket id — pass --ticket <id>."
  [ -n "$TESTS" ] && [ -d "$TESTS" ] || die "no tests dir — pass --tests <dir>."

  # The Test Writer MUST produce failing tests — an empty set is a no-op session,
  # not a valid Phase 1. Refuse it so we never hand the Implementer nothing.
  local count; count="$(find "$TESTS" -type f | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ] || die "the tests dir is empty — the Test Writer produced no tests."

  # GUARDRAIL 3 (before quarantine, so a junk suite never lands): the tests must
  # actually assert something, or a sandbagging Test Writer hands over a contract
  # that proves nothing.
  suite_has_assertions "$TESTS" \
    || die "the Test Writer's suite asserts nothing — no assertion found in any test file. A zero-assertion contract proves nothing; rejected by the test-quality guardrail."

  # Quarantine the files to tickets/<id>/tests/. That dir is the sole handoff to
  # the Implementer, so Phase 1 output never leaks into the working tree.
  local tdir; tdir="$(ticket_dir "$TICKET")/tests"
  local snap; snap="$(ticket_dir "$TICKET")/tests.sha256"
  rm -rf "$tdir"; mkdir -p "$tdir"
  ( cd "$TESTS" && cp -R . "$tdir/" )

  # GUARDRAIL 2 setup: snapshot the quarantined files so impl-save-result can
  # prove the Implementer never edited the locked contract.
  snapshot_tests "$tdir" "$snap"

  # GUARDRAIL 1 (the red gate): the suite must FAIL against no implementation
  # before the Implementer is allowed to run. A green-on-nothing suite is
  # rejected and the quarantine is rolled back, so nothing reaches the Implementer.
  if ! red_gate_ok "$tdir"; then
    rm -rf "$tdir" "$snap"
    die "the Test Writer's suite PASSED with no implementation — a contract that is green before anything is built proves nothing. Rejected by the red gate (the tests must FAIL first)."
  fi

  echo "IMPLEMENT: tests saved — $TICKET"
  echo "  Saved $count Test Writer file(s) to tickets/$TICKET/tests/."
  echo "  Red gate: suite fails as required; the contract is locked (immutable)."
  exit 0
}

# --- subcommand: impl-save-result ------------------------------------------
cmd_impl_save_result() {
  locate_mission "$MISSION_ID"
  require_stage implement
  [ -n "$TICKET" ] || die "no ticket id — pass --ticket <id>."
  [ -n "$RESULT" ] && [ -f "$RESULT" ] || die "no result file — pass --result <file>."

  # The Implementer runs only after the Test Writer: its sole handoff is the
  # on-disk tests (no shared session), so a result with no saved tests is invalid.
  local tdir; tdir="$(ticket_dir "$TICKET")/tests"
  [ -d "$tdir" ] && [ -n "$(find "$tdir" -type f -print -quit)" ] \
    || die "no tests on disk for $TICKET — run impl-save-tests first (the Implementer builds against them)."

  # GUARDRAIL 2 (immutable tests): the locked contract must be byte-for-byte the
  # snapshot taken at impl-save-tests. If the Implementer edited / added / removed
  # any test file, "green" was reached by weakening the contract, not by building
  # — reject the result before it is saved or committed.
  tests_unchanged "$TICKET" \
    || die "the Implementer modified the locked test files for $TICKET — green must be earned by implementing, never by weakening the contract. Result rejected by the immutable-tests guardrail."

  # Shape contract — same spirit as the research/plan/verdict guards: every
  # result carries all four fields, and a malformed reply stops the save.
  grep -q '"ticketId"' "$RESULT" || die "result is missing \"ticketId\"."
  grep -q '"passed"'   "$RESULT" || die "result is missing \"passed\"."
  grep -q '"attempts"' "$RESULT" || die "result is missing \"attempts\"."
  grep -q '"summary"'  "$RESULT" || die "result is missing \"summary\"."

  local rid passed attempts
  rid="$(json_str "$RESULT" ticketId)"
  passed="$(json_raw "$RESULT" passed)"
  attempts="$(json_raw "$RESULT" attempts)"

  [ "$rid" = "$TICKET" ] || die "result ticketId \"$rid\" does not match --ticket \"$TICKET\"."
  case "$passed" in true|false) : ;; *) die "result \"passed\" must be true or false." ;; esac
  case "$attempts" in
    ''|*[!0-9]*) die "result \"attempts\" must be a number." ;;
  esac
  [ "$attempts" -ge 1 ] || die "result \"attempts\" must be at least 1."
  # The Implementer iterates AT MOST 5 times; more than that breaks the cap and
  # means the loop ran away — refuse it rather than record an impossible result.
  [ "$attempts" -le "$MAX_ATTEMPTS" ] \
    || die "result \"attempts\" is $attempts — over the cap of $MAX_ATTEMPTS; a ticket flags the human at $MAX_ATTEMPTS."

  cp "$RESULT" "$(ticket_dir "$TICKET")/result.json"

  if [ "$passed" = "false" ]; then
    # The Implementer exhausted its attempts. Flag the human — same awaiting-human
    # gate shape as validate-pause / the plan-review escalation: persist the
    # blocker, set the state fields, overlay the label, and stop.
    local q; q="$(mktemp)"
    printf 'Ticket %s could not be made green after %s attempt(s): %s\n' \
      "$TICKET" "$attempts" "$(json_str "$RESULT" summary)" >"$q"
    write_pending "$q" "implement"
    state_set_raw awaitingHuman true
    state_set_str pendingQuestion "Ticket $TICKET failed after $attempts attempt(s) — needs a human."
    gh_relabel "lcars:awaiting-human" ""
    rm -f "$q"

    emit_event ticket_flagged implement "ticket $TICKET flagged after $attempts attempt(s)" \
      "ticket=$TICKET" "attempts=$attempts"

    echo "IMPLEMENT: ticket flagged — $TICKET"
    echo "  $TICKET still fails after $attempts attempt(s) (the $MAX_ATTEMPTS-attempt cap)."
    echo "  Saved result.json and flagged the human. Stage: implement (awaiting-human)."
    echo "  Resolve with \`lcars respond $MISSION_ID\`."
    [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
    exit 0
  fi

  # Ticket is green — commit its produced files to the mission branch so the
  # eventual PR has content (the working tree is otherwise left uncommitted).
  commit_ticket "$TICKET" "$(json_str "$RESULT" summary)"

  # ticket_green is emitted ONLY HERE — AFTER the immutable-tests check, the
  # shape/attempts validation (both `die` earlier on rejection) AND commit_ticket.
  # A guardrail-rejected save has already exited non-zero above, so it can never
  # reach this line: a rejected ticket never emits green.
  emit_event ticket_green implement "ticket $TICKET green in $attempts attempt(s)" \
    "ticket=$TICKET" "attempts=$attempts"

  # RULE A (issue-close lifecycle): the ticket is green AND committed, so close
  # its per-ticket sub-issue — relabel lcars:implement → lcars:done, then close.
  # This sits AFTER the guardrails (immutable tests / shape — both `die` above)
  # AND after commit_ticket: a sub-issue close must never imply a pass that a
  # guardrail rejected. The forge calls go through the host adapter (the ONE
  # forge seam), and are best-effort like commit_ticket / gh_relabel — a failure
  # leaves a note but NEVER fails the already-saved result. A null issue (a
  # local-only mission whose Schedule created no sub-issue) makes no call at all.
  local CLOSE_NOTE="" tissue parent_issue
  tissue="$(ticket_issue "$MISSION_DIR/waves.json" "$TICKET")"
  # Session-33 interplay guard: in the single-ticket Schedule fast-path the lone
  # ticket's issue IS the Mission's OWN parent issue (Schedule reused it instead
  # of opening a redundant sub-issue — BUG-005). Closing it here, on green, would
  # close the parent BEFORE the PR merges. So when tissue == the Mission's
  # githubIssue, SKIP the relabel+close entirely; the parent closes on MERGE
  # (lcars-approve), not on a green ticket.
  parent_issue="$(json_raw "$STATE" githubIssue)"
  case "$tissue" in
    ''|null)
      # No sub-issue on file for this ticket — local-only path, nothing to close.
      CLOSE_NOTE="  ⓘ no sub-issue on file for $TICKET — skipped issue close (local-only mission)."
      ;;
  esac
  if [ -z "$CLOSE_NOTE" ] && [ -n "$parent_issue" ] && [ "$parent_issue" != "null" ] \
     && [ "$tissue" = "$parent_issue" ]; then
    # Reused-parent fast-path: leave it open; it closes on PR merge.
    CLOSE_NOTE="  ⓘ ticket $TICKET reuses the Mission issue #$tissue — left open; it closes on PR merge."
  fi
  case "$tissue" in
    ''|null) : ;;  # already handled above
    "$parent_issue") : ;;  # reused-parent guard handled above
    *)
      if command -v "$GH_BIN" >/dev/null 2>&1; then
        host issue-relabel "$tissue" --add "lcars:done" --remove "lcars:implement" \
          || CLOSE_NOTE="  ⚠ could not relabel sub-issue #$tissue — relabel + close it by hand."
        host issue-close "$tissue" \
          || CLOSE_NOTE="  ⚠ could not close sub-issue #$tissue — close it by hand."
      else
        CLOSE_NOTE="  ⚠ gh not found — close sub-issue #$tissue by hand (add lcars:done, remove lcars:implement)."
      fi
      ;;
  esac

  echo "IMPLEMENT: result saved — $TICKET"
  echo "  $TICKET passed in $attempts attempt(s). Saved result.json."
  [ -n "$COMMIT_NOTE" ] && echo "$COMMIT_NOTE"
  [ -n "$CLOSE_NOTE" ] && echo "$CLOSE_NOTE"
  exit 0
}

# --- subcommand: impl-status -----------------------------------------------
# Read-only. The current wave is the lowest-numbered wave that still has an
# unfinished (not-green) ticket — Claude builds exactly that wave's pending
# tickets next. By never naming a later wave while an earlier one has open work,
# this enforces the sequential-wave rule: wave N+1 stays hidden until wave N is
# entirely green.
cmd_impl_status() {
  locate_mission "$MISSION_ID"
  require_stage implement

  local waves="$MISSION_DIR/waves.json"
  [ -f "$waves" ] || die "no waves.json — Schedule has not grouped the tickets yet."

  local table; table="$(parse_waves_table "$waves")"
  [ -n "$table" ] || die "waves.json has no tickets — nothing to implement."

  # Find the lowest wave with any not-green ticket, and collect that wave's
  # still-pending ticket ids (in plan order).
  local cur="" pending="" w id
  while IFS=$'\t' read -r w id; do
    [ -n "$id" ] || continue
    if ! ticket_green "$id"; then
      if [ -z "$cur" ] || [ "$w" -lt "$cur" ]; then cur="$w"; pending=""; fi
      [ "$w" = "$cur" ] && pending="${pending:+$pending }$id"
    fi
  done <<EOF
$table
EOF

  if [ -z "$cur" ]; then
    echo "IMPLEMENT: complete"
    echo "  Every ticket in every wave is green — ready to advance to Verify."
    echo "  Run \`lcars run $MISSION_ID\` (or impl-advance) to move to Verify."
    exit 0
  fi

  echo "IMPLEMENT: wave $cur active"
  echo "  Pending ticket(s) in wave $cur: $pending"
  echo "  Build these (Test Writer → Implementer) before wave $((cur + 1))."
  exit 0
}

# --- subcommand: impl-advance ----------------------------------------------
# The final gate: only when EVERY ticket in EVERY wave has a passing result does
# the Mission move to Verify. While any ticket is unfinished it refuses and names
# the first blocker — so a half-built Mission (or one with a flagged ticket) can
# never slip into Verify.
cmd_impl_advance() {
  locate_mission "$MISSION_ID"
  require_stage implement

  local waves="$MISSION_DIR/waves.json"
  [ -f "$waves" ] || die "no waves.json — Schedule has not grouped the tickets yet."

  local table; table="$(parse_waves_table "$waves")"
  [ -n "$table" ] || die "waves.json has no tickets — nothing to implement."

  local w id
  while IFS=$'\t' read -r w id; do
    [ -n "$id" ] || continue
    ticket_green "$id" \
      || die "ticket $id (wave $w) is not green yet — every ticket must pass before Verify. Run \`lcars run $MISSION_ID\` to finish the open waves."
  done <<EOF
$table
EOF

  # All green — clear any awaiting-human gate (defensive, like validate-advance)
  # and advance the Mission to Verify, keeping stage and label in step.
  state_del awaitingHuman
  state_del pendingQuestion
  rm -f "$MISSION_DIR/pending.json" "$MISSION_DIR/answers.json"

  set_stage "verify"
  gh_relabel "lcars:verify" "lcars:implement lcars:awaiting-human"

  echo "IMPLEMENT: advanced"
  echo "  Every ticket passed across all waves. Stage:  verify"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Verify stage ==========================================================
# The last Stage `lcars run` drives. When Implement has every ticket green it
# parks the Mission at "verify"; this prints the captain's pre-ship summary —
# the mission title, every completed ticket with its result, the overall test
# tally — and the two next moves (lcars approve / lcars feedback). It is
# READ-ONLY: the ship-or-send-back decision is the captain's, made with
# `lcars approve` / `lcars feedback` (their own skills), not here.
#
#   verify-summary  --mission <id>
cmd_verify_summary() {
  locate_mission "$MISSION_ID"
  require_stage verify

  local title; title="$(json_str "$STATE" title)"; title="${title:-$MISSION_ID}"

  local waves="$MISSION_DIR/waves.json"
  [ -f "$waves" ] || die "no waves.json — Implement has not run for this mission yet."
  local table; table="$(parse_waves_table "$waves")"
  [ -n "$table" ] || die "waves.json has no tickets — nothing to verify."

  echo "VERIFY: $title"
  echo "  All tickets completed:"
  local total=0 green=0 nwaves=0 w id rf attempts
  while IFS=$'\t' read -r w id; do
    [ -n "$id" ] || continue
    total=$((total + 1))
    [ "$w" -gt "$nwaves" ] && nwaves="$w"
    rf="$(ticket_dir "$id")/result.json"
    if [ -f "$rf" ] && [ "$(json_raw "$rf" passed)" = "true" ]; then
      green=$((green + 1)); attempts="$(json_raw "$rf" attempts)"
      printf '    ✓ %s — passed in %s attempt(s)\n' "$id" "${attempts:-?}"
    else
      printf '    ✗ %s — no passing result on file\n' "$id"
    fi
  done <<EOF
$table
EOF

  echo "  Test results: $green/$total ticket(s) green across $nwaves wave(s)."
  echo "  Review the changes and run the app if needed."
  echo "    lcars approve $MISSION_ID    — create the PR"
  echo "    lcars feedback $MISSION_ID   — send back with feedback"
  exit 0
}

# === Cold-worker layer (per-Stage isolation) ===============================
# Every headless Stage's LLM work runs as a COLD SUBPROCESS WORKER: a one-shot,
# non-interactive invocation of $WORKER_BIN whose prompt is assembled HERE from a
# per-Stage template plus the artifact PATHS it may read — never from any
# accumulated orchestrator context. That is what makes the hand-off airtight:
# there is no channel for a prior Stage's reasoning to leak in, even when the
# whole pipeline runs in one sitting (closes BUG-004). Because the worker is the
# host CLI behind one swappable binary, this also buys CLI portability (BUG-003):
# the Agent tool gave only isolation, a subprocess worker gives both.
#
# The driver does NO Stage reasoning. For each headless Stage it: builds the
# prompt, spawns the worker(s) (Research fans out N in parallel — a `-p` worker
# can't spawn its own subagents, so fan-out is the driver's job), captures the
# worker's on-disk output, and persists it through the existing, already-tested
# subcommands (gate/save/validate-*/plan-save/review-save/impl-*). A malformed
# output STOPS the Stage and re-dispatches up to MAX_WORKER_TRIES before
# surfacing failure — never a silent advance.

# --- restricted tool set per worker role ------------------------------------
# Read-only-on-the-repo for Validate/Plan/Review/question-gen; +web for the
# research agents; +write+shell for the Implementer. (All roles may write into
# their own scratch output dir — that is their answer channel, not the repo.)
worker_tools() { # role-keyword → comma-separated allowed-tools list
  case "$1" in
    repo-read)     echo "Read,Grep,Glob,Write" ;;
    repo-read-web) echo "Read,Grep,Glob,Write,WebSearch,WebFetch" ;;
    repo-write)    echo "Read,Grep,Glob,Write,Edit,Bash" ;;
    *)             echo "Read" ;;
  esac
}

# --- refuse to run a Stage without a real worker, LOUDLY --------------------
# The point of this build is that headless Stages are isolated, never inline. If
# no worker binary is available we must NOT silently pretend isolation — we stop
# and say so, so an inline/uncovered run can never masquerade as `⊘ isolated`.
require_worker() {
  command -v "$WORKER_BIN" >/dev/null 2>&1 && return 0
  [ -x "$WORKER_BIN" ] && return 0
  printf '  ⚠ NOT ISOLATED — no cold-worker binary on PATH (LCARS_WORKER_BIN=%s).\n' "$WORKER_BIN" >&2
  die "refusing to run this Stage inline — set \$LCARS_WORKER_BIN to your CLI (e.g. \`claude\`) so the Stage runs in a cold worker."
}

# --- the marker proving a Stage ran in a cold worker ------------------------
isolated_line() { # stage  worker-count
  printf '  ⊘ isolated — %s ran in %s cold worker(s) via %s\n' "$1" "$2" "$(basename "$WORKER_BIN")"
}

# --- spawn one cold worker --------------------------------------------------
# Assembles the prompt from a template file + the driver-supplied `extra` block
# (artifact PATHS and/or a question — NOTHING else) + where to write output, then
# invokes $WORKER_BIN one-shot with the role's restricted tools. The worker
# writes its answer into $outdir (a known filename per role); its stdout/stderr
# are captured to scratch for debugging only. The scratch dir path is also handed
# to the worker via $LCARS_WORK_OUT so a CLI adapter (or a test stub) can find it
# without re-parsing the prompt.
spawn_worker() { # role  template  toolset  outdir  extra
  local role="$1" template="$2" toolset="$3" outdir="$4" extra="$5"
  mkdir -p "$outdir"
  local prompt tools
  prompt="$(cat "$template")

$extra

## Where to write your output
Your scratch output directory is: $outdir
Write your output file(s) there exactly as specified above — nowhere else."
  tools="$(worker_tools "$toolset")"
  LCARS_WORK_OUT="$outdir" LCARS_WORKER_ROLE="$role" \
    "$WORKER_BIN" -p "$prompt" --allowedTools "$tools" --output-format text \
    >"$outdir/.worker.out" 2>"$outdir/.worker.err" || true
}

# === Stage driver: Research ================================================
# Fresh-file Research: a question-generator worker reads the PRD and emits 0–20
# questions; the gate decides skip / dispatch / escalate; on dispatch the driver
# fans out one stateless research worker PER question, in parallel, each given
# only its question text; then `save` persists the findings and advances.
cmd_research() {
  locate_mission "$MISSION_ID"
  require_stage align
  require_worker
  [ -f "$MISSION_DIR/prd.md" ] || die "no prd.md — Align has not produced a PRD for '$MISSION_ID'."
  # NOTE: a feedback re-entry (feedback.md present at align) is handled by the
  # dispatch in SKILL.md — Claude re-grills against prd.md + feedback.md and
  # rewrites prd.md on the host CLI FIRST, then runs this driver. So Research
  # always reads the current prd.md; the presence of feedback.md is not a guard
  # here (the re-grill leaves it in place as durable history).

  # STEP 1 — question-generator worker → questions.txt
  local qdir="" tries=0
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    qdir="$(mktemp -d)"
    spawn_worker research-questions "$STAGES_DIR/research-questions.md" repo-read "$qdir" \
"## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/prd.md"
    [ -f "$qdir/questions.txt" ] && break
    rm -rf "$qdir"; qdir=""
  done
  [ -n "$qdir" ] || die "the question-generator worker produced no questions.txt after $MAX_WORKER_TRIES attempt(s) — Stage stopped, no advance."

  # STEP 2 — gate on the count (reuse the tested subcommand; it owns skip/escalate)
  local gate_out gate_rc=0
  gate_out="$(LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" gate \
    --mission "$MISSION_ID" --questions "$qdir/questions.txt" 2>&1)" || gate_rc=$?
  printf '%s\n' "$gate_out"
  case "$gate_out" in
    *"GATE: skip"*)      isolated_line research 1; rm -rf "$qdir"; exit 0 ;;
    *"GATE: too-many"*)  isolated_line research 1; rm -rf "$qdir"; exit "$gate_rc" ;;
  esac

  # STEP 3 — fan out one stateless research worker per question, IN PARALLEL.
  # Each is given ONLY its question text — no PRD, no siblings (CONTEXT.md →
  # Research Agent). Shell job control is the fan-out: a `-p` worker can't spawn
  # its own subagents.
  local resp; resp="$(mktemp -d)"
  local i=0 q
  local pids=""
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    i=$((i + 1))
    local adir; adir="$resp/$(printf '%03d' "$i")"
    research_agent_worker "$adir" "$q" &
    pids="$pids $!"
  done < <(grep -ve '^[[:space:]]*$' "$qdir/questions.txt")
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null

  # STEP 4 — collect into a flat responses dir and save (reuse the tested
  # subcommand; it validates each response and refuses to advance on bad data).
  local flat; flat="$(mktemp -d)"
  local n=0 d
  for d in "$resp"/*/; do
    [ -f "${d}response.json" ] || continue
    n=$((n + 1)); cp "${d}response.json" "$flat/$(printf '%03d' "$n").json"
  done

  local save_rc=0
  LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" save \
    --mission "$MISSION_ID" --responses "$flat" || save_rc=$?
  if [ "$save_rc" -ne 0 ]; then
    rm -rf "$qdir" "$resp" "$flat"
    die "research workers produced malformed findings that failed validation after $MAX_WORKER_TRIES attempt(s) per agent — Stage stopped, no advance."
  fi
  isolated_line research "$((i + 1))"
  rm -rf "$qdir" "$resp" "$flat"
  exit 0
}

# One research agent, retried until it yields a well-shaped response (or the cap).
# Runs in a background subshell (no `local`, no `exit` that escapes the parent).
research_agent_worker() { # outdir  question
  local adir="$1" q="$2" t=0
  while [ "$t" -lt "$MAX_WORKER_TRIES" ]; do
    t=$((t + 1))
    rm -rf "$adir"
    spawn_worker research-agent "$STAGES_DIR/research-agent.md" repo-read-web "$adir" \
"## The one question you must answer (your ONLY context)
«${q}»"
    if [ -f "$adir/response.json" ] \
      && grep -q '"recommendation"'    "$adir/response.json" \
      && grep -q '"supporting_points"' "$adir/response.json"; then
      return 0
    fi
  done
  return 0   # leave the malformed/absent output; `save` will reject and the Stage stops
}

# === Stage driver: Validate ================================================
# One cold worker fed ONLY prd.md + research/*.json. It writes validated-plan.md
# and (optionally) scope.txt; the driver persists via validate-pause (scope
# questions present) or validate-advance (none), retrying on a malformed plan.
cmd_validate() {
  locate_mission "$MISSION_ID"
  require_stage validate
  require_worker
  [ "$(json_raw "$STATE" awaitingHuman)" = "true" ] \
    && die "mission is awaiting a human answer — run \`lcars respond $MISSION_ID\` first; the Validator does not re-run until the gate clears."
  [ -f "$MISSION_DIR/prd.md" ] || die "no prd.md."

  # Zero findings is a VALID Validate input. A 0-question Research (unambiguous
  # PRD) advances align→validate via the gate's "skip" path WITHOUT creating a
  # research/ dir, so an absent or empty research/ means "the PRD was clear" —
  # not "Research never ran". Synthesise from the PRD alone in that case; only
  # list research/*.json when they actually exist (the loop below is already a
  # no-op for a missing glob). Order is still enforced by require_stage validate
  # above, and a malformed synthesis still dies in cmd_save before advancing —
  # so dropping the old hard `-d research` guard cannot let a pre-Research
  # validate slip through.
  local extra; extra="## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/prd.md"
  local f
  for f in "$MISSION_DIR"/research/*.json; do
    [ -f "$f" ] && extra="$extra
- $f"
  done
  # RESUME after `lcars respond`: the captain's recorded answer resolves the
  # prior scope question. Feed it so the fresh Validator FOLDS IT IN and does not
  # re-raise the same question — otherwise the awaiting-human gate loops forever.
  [ -f "$MISSION_DIR/answers.json" ] && extra="$extra
- $MISSION_DIR/answers.json   (the captain's answer resolving the prior scope question — treat it as DECIDED and fold it in; do not re-raise it)"
  # The durable repo context source (CONTEXT.md or the generated pack) — shared
  # declarative facts, by PATH only. Safe for this declarative Stage.
  extra="$extra$(context_extra_block)"

  local tries=0
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    local odir; odir="$(mktemp -d)"
    spawn_worker validate "$STAGES_DIR/validate.md" repo-read "$odir" "$extra"

    if [ -f "$odir/scope.txt" ] && grep -qve '^[[:space:]]*$' "$odir/scope.txt"; then
      # A finding implies a scope change → pause at the human gate (a valid
      # outcome, not a failure). validate-pause keeps the card in Validate.
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" validate-pause \
        --mission "$MISSION_ID" --questions "$odir/scope.txt"
      isolated_line validate 1; rm -rf "$odir"; exit 0
    fi

    if [ -f "$odir/validated-plan.md" ]; then
      local rc=0
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" validate-advance \
        --mission "$MISSION_ID" --plan "$odir/validated-plan.md" || rc=$?
      if [ "$rc" -eq 0 ]; then isolated_line validate 1; rm -rf "$odir"; exit 0; fi
    fi
    rm -rf "$odir"
  done
  die "the Validate worker produced an artifact that failed validation after $MAX_WORKER_TRIES attempt(s) — Stage stopped, no advance."
}

# === Stage driver: Plan ====================================================
# One cold worker fed ONLY prd.md + validated-plan.md → plan.json, persisted via
# plan-save (which validates every ticket, incl. its rationale).
cmd_plan() {
  locate_mission "$MISSION_ID"
  require_stage plan
  require_worker
  [ -f "$MISSION_DIR/prd.md" ] || die "no prd.md."
  [ -f "$MISSION_DIR/validated-plan.md" ] || die "no validated-plan.md — Validate has not run."

  # comprehensionBudget is a PLANNING TARGET (sum of read+test+new), not a hard
  # cap — see validate_plan_json's design note. Read it from config, default 1200.
  local budget; budget="$(json_raw "$LCARS_CFG" comprehensionBudget)"; budget="${budget:-1200}"

  local extra="## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/prd.md
- $MISSION_DIR/validated-plan.md

## Your comprehension budget
comprehensionBudget = $budget — the per-ticket target for total comprehension
load (estimatedReadLoc + estimatedTestLoc + estimatedNewLoc). It is a PLANNING
TARGET, not a hard cap: cohesion comes first (one user-observable behavior per
ticket), size is the secondary guardrail. A ticket may run over budget when a
large existing file makes estimatedReadLoc alone unavoidable — that is fine.
What is NOT fine is being over budget because the ticket BUNDLES two behaviors."
  # On a Plan Review loop-back the Mission is back at `plan` with the reviewer's
  # objections on disk. Feed them so the fresh Planner worker actually revises
  # against them (otherwise it would re-emit the rejected plan and loop to the
  # round-3 escalation). The objections are the only extra input on a revise.
  local rv
  for rv in "$MISSION_DIR"/plan-review-*.json; do
    [ -f "$rv" ] && extra="$extra
- $rv   (reviewer objections to resolve in this revision)"
  done
  # Shared declarative repo facts, by PATH only.
  extra="$extra$(context_extra_block)"

  local tries=0
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    local odir; odir="$(mktemp -d)"
    spawn_worker plan "$STAGES_DIR/plan.md" repo-read "$odir" "$extra"
    if [ -f "$odir/plan.json" ]; then
      local rc=0
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" plan-save \
        --mission "$MISSION_ID" --plan "$odir/plan.json" || rc=$?
      if [ "$rc" -eq 0 ]; then isolated_line plan 1; rm -rf "$odir"; exit 0; fi
    fi
    rm -rf "$odir"
  done
  die "the Plan worker produced a plan.json that failed validation after $MAX_WORKER_TRIES attempt(s) — Stage stopped, no advance."
}

# === Stage driver: Plan Review =============================================
# A FRESH cold worker fed ONLY plan.json (never prd.md / validated-plan.md) →
# verdict.json, persisted via review-save (pass→Schedule, fail→loop/escalate).
cmd_plan_review() {
  locate_mission "$MISSION_ID"
  require_stage plan-review
  require_worker
  [ "$(json_raw "$STATE" awaitingHuman)" = "true" ] \
    && die "mission is awaiting a human answer — run \`lcars respond $MISSION_ID\` first; the reviewer does not re-run until the gate clears."
  [ -f "$MISSION_DIR/plan.json" ] || die "no plan.json — Plan has not run."

  # comprehensionBudget is the size yardstick the reviewer applies — a PLANNING
  # TARGET, not a hard cap (see validate_plan_json's design note). Default 1200.
  local budget; budget="$(json_raw "$LCARS_CFG" comprehensionBudget)"; budget="${budget:-1200}"

  # Independence is the whole point: the reviewer is handed the tickets ALONE.
  local extra="## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/plan.json

## Your comprehension budget
comprehensionBudget = $budget — apply it to each ticket's total comprehension
load (estimatedReadLoc + estimatedTestLoc + estimatedNewLoc). It is a PLANNING
TARGET, not a hard cap: an over-budget ticket is an objection ONLY when the
overage is driven by BUNDLING (two behaviors that should be split). When the
overage is unavoidable existing code (a big file the ticket must read), it is
acceptable — do not raise it."
  # RESUME after a round-3 escalation: the captain's recorded answer (override /
  # redirect) resolves the standoff. Feed it so the reviewer honours that
  # decision instead of re-escalating the same objections forever.
  [ -f "$MISSION_DIR/answers.json" ] && extra="$extra
- $MISSION_DIR/answers.json   (the captain's resolution of the prior escalation — treat it as DECIDED; do not re-raise it)"
  # The reviewer still sees ONLY the tickets (never prd.md / validated-plan.md) —
  # we add nothing but the declarative repo-facts context source, by PATH only.
  extra="$extra$(context_extra_block)"

  local tries=0
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    local odir; odir="$(mktemp -d)"
    spawn_worker plan-review "$STAGES_DIR/plan-review.md" repo-read "$odir" "$extra"
    if [ -f "$odir/verdict.json" ]; then
      local rc=0
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" review-save \
        --mission "$MISSION_ID" --verdict "$odir/verdict.json" || rc=$?
      if [ "$rc" -eq 0 ]; then isolated_line plan-review 1; rm -rf "$odir"; exit 0; fi
    fi
    rm -rf "$odir"
  done
  die "the Plan Review worker produced a verdict that failed validation after $MAX_WORKER_TRIES attempt(s) — Stage stopped, no advance."
}

# === Stage driver: Implement (one ticket) ==================================
# The adversarial pair, both cold workers: a Test Writer fed only the approved
# ticket writes failing tests (quarantined via impl-save-tests — its ONLY channel
# to the Implementer), then a SEPARATE Implementer fed only the ticket + those
# on-disk tests makes them pass (persisted via impl-save-result). The two never
# share a session.
cmd_implement_ticket() {
  locate_mission "$MISSION_ID"
  require_stage implement
  require_worker
  [ -n "$TICKET" ] || die "no ticket id — pass --ticket <id>."
  [ -f "$MISSION_DIR/approved-plan.json" ] || die "no approved-plan.json — Schedule has not run."

  # Record the captain's pre-existing untracked files BEFORE any worker touches
  # the tree, so commit_ticket stages only the Implementer's NEW source — never
  # the captain's unrelated files or the worker's scratch (see commit_ticket).
  mkdir -p "$(ticket_dir "$TICKET")"
  snapshot_untracked "$(ticket_dir "$TICKET")/.untracked-before"

  # ticket_start — look up this ticket's wave in waves.json (jq-free). IDEMPOTENT:
  # implement-ticket is re-invoked on the same ticket (manual retry, or the
  # respond→run resume of a flagged ticket), so emit at most once EVER per
  # (mission, ticket) by checking events.jsonl first.
  local tw; tw="$(parse_waves_table "$MISSION_DIR/waves.json" 2>/dev/null | awk -F'\t' -v t="$TICKET" '$2==t{print $1; exit}')"
  event_seen ticket_start "\"ticket\":\"$TICKET\"" \
    || emit_event ticket_start implement "ticket $TICKET starting" "ticket=$TICKET" "wave=${tw:-0}"

  # NOTE: `attempt` in the ticket_attempt events below is the CUMULATIVE
  # worker-DISPATCH count for this (ticket, phase) ACROSS invocations — one index
  # per real spawn_worker dispatch, derived from events.jsonl so it never repeats
  # or restarts when a fresh process re-enters. DISTINCT from the Implementer's
  # own internal 1–5 attempts that land in result.json.attempts.attempts.
  # The durable repo context source (shared declarative facts, by PATH only) —
  # resolved once for both halves of the adversarial pair.
  local cblock; cblock="$(context_extra_block)"

  # PHASE 1 — Test Writer worker → tests/ → impl-save-tests
  local tries=0 saved=0
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    # attempt = 1 + (existing ticket_attempt lines for THIS ticket+phase). Within
    # one invocation this is 1,2,3; a re-invocation continues 4,5,6 — one unique
    # index per real spawn_worker dispatch below, never a repeat.
    local awtry; awtry=$(( $(event_count ticket_attempt "\"ticket\":\"$TICKET\".*\"phase\":\"test-writer\"") + 1 ))
    emit_event ticket_attempt implement "test-writer try $awtry for $TICKET" \
      "ticket=$TICKET" "phase=test-writer" "attempt=$awtry"
    local odir; odir="$(mktemp -d)"
    spawn_worker implement-test-writer "$STAGES_DIR/implement-test-writer.md" repo-read "$odir" \
"## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/approved-plan.json$cblock

## Your ticket
$TICKET"
    if [ -d "$odir/tests" ] && [ -n "$(find "$odir/tests" -type f -print -quit 2>/dev/null)" ]; then
      local rc=0
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" impl-save-tests \
        --mission "$MISSION_ID" --ticket "$TICKET" --tests "$odir/tests" || rc=$?
      if [ "$rc" -eq 0 ]; then saved=1; rm -rf "$odir"; break; fi
    fi
    rm -rf "$odir"
  done
  [ "$saved" = 1 ] || die "the Test Writer worker produced no usable tests for $TICKET after $MAX_WORKER_TRIES attempt(s) — Stage stopped."

  # PHASE 2 — Implementer worker (no Test Writer context) → result.json →
  # impl-save-result. Its ONLY handoff is the tests now on disk.
  local tdir; tdir="$(ticket_dir "$TICKET")/tests"
  local iextra="## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/approved-plan.json
- $tdir   (the failing tests — your entire handoff from the Test Writer)$cblock"
  # RESUME after a 5-attempt flag was answered: the captain's recorded note is
  # how to get this ticket unstuck. Feed it so the Implementer acts on it rather
  # than re-flagging the same blocker.
  [ -f "$MISSION_DIR/answers.json" ] && iextra="$iextra
- $MISSION_DIR/answers.json   (the captain's answer resolving the prior block on this ticket — treat it as DECIDED)"
  iextra="$iextra

## Your ticket
$TICKET"
  tries=0
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    # Same cumulative-from-the-log numbering as Phase 1, for the implementer phase.
    local aitry; aitry=$(( $(event_count ticket_attempt "\"ticket\":\"$TICKET\".*\"phase\":\"implementer\"") + 1 ))
    emit_event ticket_attempt implement "implementer try $aitry for $TICKET" \
      "ticket=$TICKET" "phase=implementer" "attempt=$aitry"
    local odir; odir="$(mktemp -d)"
    spawn_worker implement-implementer "$STAGES_DIR/implement-implementer.md" repo-write "$odir" "$iextra"
    if [ -f "$odir/result.json" ]; then
      local rc=0
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" impl-save-result \
        --mission "$MISSION_ID" --ticket "$TICKET" --result "$odir/result.json" || rc=$?
      if [ "$rc" -eq 0 ]; then isolated_line "implement($TICKET)" 2; rm -rf "$odir"; exit 0; fi
    fi
    rm -rf "$odir"
  done
  die "the Implementer worker produced a result for $TICKET that failed validation after $MAX_WORKER_TRIES attempt(s) — Stage stopped, no advance."
}

# === Stage driver: Implement (the whole stage) =============================
# The token-free wave loop. It processes the waves in order and, within a wave,
# builds every pending ticket through `implement-ticket` (the cold adversarial
# pair), then advances to Verify once every ticket is green. It composes the
# already-tested impl-* subcommands and adds NO new Stage logic — it only
# sequences them, the same way the auto-advance driver sequences whole Stages.
# A ticket that flags the human (the 5-attempt cap → awaiting-human) stops the
# loop at the gate; a hard worker failure stops the Stage non-zero.
cmd_implement() {
  locate_mission "$MISSION_ID"
  require_stage implement
  require_worker

  # For the wave_start instrumentation: totalWaves (distinct wave count) and a
  # per-wave ticket count, both derived jq-free from waves.json via parse_waves_table.
  local waves_file="$MISSION_DIR/waves.json"
  local total_waves; total_waves="$(parse_waves_table "$waves_file" 2>/dev/null | cut -f1 | sort -un | grep -c .)"

  local last_status="" last_wave=""
  while :; do
    local st rc=0
    st="$(LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" impl-status --mission "$MISSION_ID" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$st" >&2
      die "impl-status failed — Implement cannot sequence the waves."
    fi

    case "$st" in
      *"IMPLEMENT: complete"*)
        # Every ticket is green — advance to Verify (it re-checks all waves).
        LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" impl-advance --mission "$MISSION_ID"
        exit $? ;;
      *"IMPLEMENT: wave "*) : ;;   # a wave is active — build its pending tickets
      *) printf '%s\n' "$st" >&2; die "unexpected impl-status output — Stage stopped." ;;
    esac

    # Emit wave_start ONCE per wave, in ascending order. impl-status re-runs every
    # pass, AND cmd_implement itself is re-invoked on real runs (manual retry /
    # respond→run resume), so the in-process last_wave guard is not enough —
    # dedup durably against events.jsonl. Match "wave":N at an INTEGER boundary
    # (followed by , or }) so "wave":1 never matches "wave":10. M = the wave's
    # FULL ticket count from waves.json (on first sight all its tickets are pending).
    local cur_wave; cur_wave="$(printf '%s\n' "$st" | sed -n 's/.*IMPLEMENT: wave \([0-9]*\) active.*/\1/p')"
    if [ -n "$cur_wave" ] && [ "$cur_wave" != "$last_wave" ] \
       && ! event_seen wave_start "\"wave\":$cur_wave[,}]"; then
      local wcount; wcount="$(parse_waves_table "$waves_file" 2>/dev/null | awk -F'\t' -v w="$cur_wave" '$1==w{n++} END{print n+0}')"
      emit_event wave_start implement "wave $cur_wave starting ($wcount ticket(s))" \
        "wave=$cur_wave" "ticketCount=$wcount" "totalWaves=$total_waves"
    fi
    last_wave="$cur_wave"

    # No-progress guard: if a full pass leaves impl-status reporting exactly the
    # same wave + pending set, we'd loop forever — stop loudly instead.
    [ "$st" != "$last_status" ] \
      || die "Implement made no progress on the current wave — Stage stopped (a ticket neither went green nor flagged)."
    last_status="$st"

    local pending; pending="$(printf '%s\n' "$st" | sed -n 's/.*Pending ticket(s) in wave [0-9]*: //p')"
    [ -n "$pending" ] || die "impl-status named an active wave but listed no pending tickets — Stage stopped."

    local t
    for t in $pending; do
      local irc=0
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" implement-ticket \
        --mission "$MISSION_ID" --ticket "$t" || irc=$?
      [ "$irc" -eq 0 ] || die "implement-ticket $t failed — Stage stopped, no advance."
      # A flagged ticket parks the Mission at the awaiting-human gate. Stop here;
      # the auto-advance driver detects the gate and notifies.
      [ "$(json_raw "$STATE" awaitingHuman)" = "true" ] && exit 0
    done
  done
}

# === The auto-advance driver ===============================================
# `lcars run <id>` defaults to AUTO mode: a thin, token-free loop that sequences
# the per-Stage advances above — each spawned as a cold isolated worker — back to
# back until a halt condition, then returns to the human. `--step` runs exactly
# ONE Stage and stops (the previous one-stage-per-invocation behaviour, kept for
# debugging). The driver does NO Stage reasoning: every advance is the same
# subprocess `--step` would call, so auto mode inherits each Stage's behaviour —
# and its cold-worker isolation — for free.
#
# HALT CONDITIONS (stop and return to the human):
#   awaitingHuman === true        a Stage escalated a question → notify + print it
#   stage === "verify"            the human review gate — never auto-passed → notify
#   stage === "align" + feedback  a Verify feedback re-entry needs an interactive
#                                 Align re-grill (a human grilling session)
#   stage === "done"              terminal
#   a Stage errors                stop, surface it, do not continue

# --- the walk-away ping: fire the notify hook ONCE, only at a human gate -----
notify_gate() { # gate-type  one-line-decision-ready-summary
  LCARS_CFG="$LCARS_CFG" "$NOTIFY_BIN" "$MISSION_ID" "$1" "$2" || true
}

# --- print pending.json's questions, one bare string per line ----------------
# The questions are the lone-quoted-string array items; key/value lines (which
# carry a ": ") never match, so "stage" is skipped.
drive_pending_questions() { # pending.json
  grep -oE '^[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$' "$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*,?[[:space:]]*$//'
}

# --- one concise detail phrase per Stage, parsed from its output -------------
drive_detail() { # stage  stage-output
  case "$1" in
    align|research)
      case "$2" in
        *"GATE: skip"*)     echo "0 questions (PRD unambiguous)" ;;
        *"GATE: too-many"*) printf '%s' "$2" | sed -n 's/.*GATE: too-many \([0-9]*\).*/\1 questions — over the cap/p' | head -1 ;;
        *"SAVE: "*)         printf '%s' "$2" | sed -n 's/.*SAVE: \([0-9]*\) responses.*/\1 research agent(s) complete/p' | head -1 ;;
        *)                  echo "research complete" ;;
      esac ;;
    validate)    echo "no scope changes" ;;
    plan)        local n; n="$(grep -c '"id"' "$MISSION_DIR/plan.json" 2>/dev/null)"; echo "${n:-?} ticket(s)" ;;
    plan-review)
      case "$2" in
        *"passed"*) echo "passed review" ;;
        *"revise"*) printf '%s' "$2" | sed -n 's/.*revise — round \([0-9]*\).*/revise (round \1) → plan/p' | head -1 ;;
        *)          echo "reviewed" ;;
      esac ;;
    schedule)    printf '%s' "$2" | sed -n 's/.*into \([0-9]*\) wave(s).*/\1 wave(s)/p' | head -1 ;;
    implement)
      local total=0 g=0 w id
      while IFS=$'\t' read -r w id; do
        [ -n "$id" ] || continue; total=$((total + 1)); ticket_green "$id" && g=$((g + 1))
      done < <(parse_waves_table "$MISSION_DIR/waves.json" 2>/dev/null)
      echo "$g/$total ticket(s) green" ;;
    *)           echo "done" ;;
  esac
}

# --- one summary line for a Stage that just ran ------------------------------
drive_line() { # stage  stage-output  ok|paused
  if [ "$3" = paused ]; then
    printf '%-12s ⏸  escalated — awaiting your answer' "$1"
    return
  fi
  local detail iso=""
  detail="$(drive_detail "$1" "$2")"
  printf '%s' "$2" | grep -q 'isolated' && iso="   ⊘ isolated"
  printf '%-12s ✓  %s%s' "$1" "${detail:-advanced}" "$iso"
}

drive_print_summary() { # accumulated-lines
  [ -n "$1" ] && printf '%s\n' "$1"
  printf '%s\n' "$SEP"
}

drive_halt_verify() {
  printf '⏹ stopped at: verify  (human review required)\n'
  printf 'Review the changes and run the app, then:\n'
  printf '  lcars approve %s    — create the PR\n' "$MISSION_ID"
  printf '  lcars feedback %s   — send back with feedback\n' "$MISSION_ID"
  local title; title="$(json_str "$STATE" title)"; title="${title:-$MISSION_ID}"
  notify_gate verify "$title is ready for review — \`lcars approve $MISSION_ID\` to ship, or \`lcars feedback $MISSION_ID\` to send it back."
}

drive_halt_awaiting() { # stage
  printf '⏹ stopped at: %s  (awaiting your answer)\n' "$1"
  local pj="$MISSION_DIR/pending.json" q
  if [ -f "$pj" ]; then
    printf 'Pending question(s):\n'
    while IFS= read -r q; do
      [ -n "$q" ] && printf '  • %s\n' "$q"
    done < <(drive_pending_questions "$pj")
  fi
  printf 'Answer with `lcars respond %s`.\n' "$MISSION_ID"
  local first; first="$(json_str "$STATE" pendingQuestion)"
  notify_gate awaiting-human "Needs your answer — ${first:-see \`lcars respond $MISSION_ID\`}"
}

drive_halt_align() {
  printf '⏹ stopped at: align  (interactive Align re-grill required)\n'
  printf 'This Mission was sent back from Verify (feedback.md is present). Align is a\n'
  printf 'human grilling session, not automatable: re-grill it in your session and\n'
  printf 'rewrite the PRD, then it auto-advances from Research.\n'
}

cmd_drive() {
  locate_mission "$MISSION_ID"
  local mode="auto"; [ "$STEP" = 1 ] && mode="step"
  printf '%s  %s-advance\n%s\n' "$MISSION_ID" "$mode" "$SEP"

  local summary=""
  while :; do
    # Re-read the live state each pass (a Stage subprocess just rewrote it).
    local stage awaiting
    stage="$(json_str "$STATE" stage)"
    awaiting="$(json_raw "$STATE" awaitingHuman)"

    # Halt conditions, checked BEFORE running anything. Each emits a `gate` event
    # to the Mission log (the halt block + notify hook below are unchanged).
    if [ "$awaiting" = "true" ]; then
      emit_event gate "$stage" "awaiting your answer"
      drive_print_summary "$summary"; drive_halt_awaiting "$stage"; return 0
    fi
    case "$stage" in
      verify) emit_event gate verify "human review required"
              drive_print_summary "$summary"; drive_halt_verify; return 0 ;;
      done)   emit_event gate done "Mission shipped — the PR is open"
              drive_print_summary "$summary"
              printf '⏹ stopped at: done  (Mission shipped — the PR is open)\n'; return 0 ;;
      align)  if [ -f "$MISSION_DIR/feedback.md" ]; then
                emit_event gate align "interactive Align re-grill required"
                drive_print_summary "$summary"; drive_halt_align; return 0
              fi ;;
    esac

    # Map the current stage to its single-Stage advance (the same subprocess
    # `--step` calls). align with no feedback.md is a freshly-filed Mission → Research.
    local action
    case "$stage" in
      align)       action="research" ;;
      validate)    action="validate" ;;
      plan)        action="plan" ;;
      plan-review) action="plan-review" ;;
      schedule)    action="schedule" ;;
      implement)   action="implement" ;;
      *) drive_print_summary "$summary"
         printf '⏹ stopped: Mission is at an unsupported stage "%s".\n' "$stage"; return 1 ;;
    esac

    # Live BEGIN: log + print before the (output-captured) stage subprocess runs,
    # so a tail/scrollback shows the Stage starting in real time.
    emit_event stage_start "$action" "starting"
    printf '%-12s ▶  running…\n' "$action"

    local out rc=0
    out="$(LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" "$action" --mission "$MISSION_ID" 2>&1)" || rc=$?

    local new_stage new_awaiting
    new_stage="$(json_str "$STATE" stage)"
    new_awaiting="$(json_raw "$STATE" awaitingHuman)"

    # Label the line by the Stage that actually ran (a fresh `align` runs Research).
    # The per-stage line is built ONCE, PRINTED LIVE immediately (so a tail shows
    # each transition as it happens), AND accumulated into $summary (the final
    # block at halt prints unchanged). The drive_line format — including the
    # `⊘ isolated` marker — is byte-identical to before.
    local line
    if [ "$new_awaiting" = "true" ]; then
      line="$(drive_line "$action" "$out" paused)"
      printf '%s\n' "$line"
      # The `gate` event + notify fire from the halt check at the top of the
      # next pass — emitting one here too would double-log the gate.
      summary="${summary:+$summary
}$line"
      continue
    fi
    if [ "$new_stage" != "$stage" ]; then
      line="$(drive_line "$action" "$out" ok)"
      printf '%s\n' "$line"
      emit_event stage_done "$action" "$(drive_detail "$action" "$out")"
      summary="${summary:+$summary
}$line"
      if [ "$mode" = "step" ]; then
        drive_print_summary "$summary"
        if [ "$new_stage" = "verify" ]; then drive_halt_verify
        else printf '⏹ stepped one Stage → now at: %s\n' "$new_stage"
             printf 'Run `lcars run %s` to continue (or add `--step` for one more).\n' "$MISSION_ID"
        fi
        return 0
      fi
      continue
    fi

    # Nothing advanced and no gate was raised → a hard Stage error.
    emit_event error "$stage" "$stage failed"
    drive_print_summary "$summary"
    printf '⏹ stopped: %s failed\n' "$stage"
    printf '%s\n' "$out"
    return "${rc:-1}"
  done
}

# --- dispatch --------------------------------------------------------------
SUB="${1:-}"; [ $# -gt 0 ] && shift

MISSION_ID=""; QFILE=""; RESPONSES=""; PLAN=""; VERDICT=""; TICKET=""; TESTS=""; RESULT=""; STEP=0
EV_TYPE=""; EV_STAGE=""; EV_DETAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --step)        STEP=1; shift ;;
    --mission)     MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*)   MISSION_ID="${1#--mission=}"; shift ;;
    --questions)   QFILE="${2:-}"; shift 2 ;;
    --questions=*) QFILE="${1#--questions=}"; shift ;;
    --responses)   RESPONSES="${2:-}"; shift 2 ;;
    --responses=*) RESPONSES="${1#--responses=}"; shift ;;
    --plan)        PLAN="${2:-}"; shift 2 ;;
    --plan=*)      PLAN="${1#--plan=}"; shift ;;
    --verdict)     VERDICT="${2:-}"; shift 2 ;;
    --verdict=*)   VERDICT="${1#--verdict=}"; shift ;;
    --ticket)      TICKET="${2:-}"; shift 2 ;;
    --ticket=*)    TICKET="${1#--ticket=}"; shift ;;
    --tests)       TESTS="${2:-}"; shift 2 ;;
    --tests=*)     TESTS="${1#--tests=}"; shift ;;
    --result)      RESULT="${2:-}"; shift 2 ;;
    --result=*)    RESULT="${1#--result=}"; shift ;;
    --type)        EV_TYPE="${2:-}"; shift 2 ;;
    --type=*)      EV_TYPE="${1#--type=}"; shift ;;
    --stage)       EV_STAGE="${2:-}"; shift 2 ;;
    --stage=*)     EV_STAGE="${1#--stage=}"; shift ;;
    --detail)      EV_DETAIL="${2:-}"; shift 2 ;;
    --detail=*)    EV_DETAIL="${1#--detail=}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$SUB" in
  gate|save|validate-pause|validate-advance|plan-save|review-save|schedule|impl-save-tests|impl-save-result|impl-status|impl-advance|verify-summary|research|validate|plan|plan-review|implement|implement-ticket|drive|emit-event)
    [ -n "$MISSION_ID" ] || die "no mission id — pass --mission <id>." ;;
esac

case "$SUB" in
  # Persistence subcommands (mechanical; no LLM) — the Stage drivers reuse these.
  gate)             cmd_gate ;;
  save)             cmd_save ;;
  validate-pause)   cmd_validate_pause ;;
  validate-advance) cmd_validate_advance ;;
  plan-save)        cmd_plan_save ;;
  review-save)      cmd_review_save ;;
  schedule)         cmd_schedule ;;
  impl-save-tests)  cmd_impl_save_tests ;;
  impl-save-result) cmd_impl_save_result ;;
  impl-status)      cmd_impl_status ;;
  impl-advance)     cmd_impl_advance ;;
  verify-summary)   cmd_verify_summary ;;
  # Stage drivers (spawn cold workers, then persist via the subcommands above).
  research)         cmd_research ;;
  validate)         cmd_validate ;;
  plan)             cmd_plan ;;
  plan-review)      cmd_plan_review ;;
  implement)        cmd_implement ;;
  implement-ticket) cmd_implement_ticket ;;
  # Auto-advance driver — sequences the per-Stage advances above (token-free).
  drive)            cmd_drive ;;
  # Repo-level context resolver (no mission) — prints the durable context source
  # path, generating the one-time pack lazily. Reused by lcars-file's Align flow.
  context-source)   cmd_context_source ;;
  # Test hook: emit one event line to the Mission event log (jq-free helper).
  emit-event)       locate_mission "$MISSION_ID"; emit_event "$EV_TYPE" "$EV_STAGE" "$EV_DETAIL" ;;
  ''|*) die "unknown subcommand '${SUB:-}'. Usage: run.sh drive --mission <id> [--step], or a single Stage. Drivers: research|validate|plan|plan-review|implement|implement-ticket|drive. Persistence: gate|save|validate-pause|validate-advance|plan-save|review-save|schedule|impl-save-tests|impl-save-result|impl-status|impl-advance|verify-summary." ;;
esac
