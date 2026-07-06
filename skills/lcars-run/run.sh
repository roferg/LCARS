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
# The cold-worker binary + model. Every headless Stage's LLM work runs as a
# one-shot invocation of this CLI. Both are RESOLVED AT RUN TIME (see
# resolve_worker, below) — not at load time — because resolution may consult the
# per-repo config.json, whose path is only known after locate_mission. The
# resolved values land in WORKER_BIN / WORKER_MODEL (+ their *_SRC sources for the
# self-explaining log line). Swapping the binary is the whole CLI-portability
# story (BUG-003): default it to whichever CLI you launched LCARS under, with an
# explicit override. Tests point WORKER_BIN at a stub that echoes canned artifacts
# so the plumbing runs token-free.
WORKER_BIN=""
WORKER_MODEL=""
WORKER_BIN_SRC=""
WORKER_MODEL_SRC=""
WORKER_RESOLVED=0   # guard so the resolution log line prints ONCE per process.
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
# The SINGLE source of truth for billing data (Claude $/MTok per tier; Copilot
# premium-request multipliers + overage). NO prices/multipliers are hardcoded in
# this script's cost logic — they all live in pricing.json. $LCARS_PRICING lets
# tests point at a fixture pricing file (e.g. one with null Copilot multipliers).
PRICING_FILE="${LCARS_PRICING:-$SKILL_DIR/pricing.json}"
# The host-integration adapter — the ONE place that speaks to a forge. Every
# GitHub call funnels through it so the integration is swappable (BUG-003). It
# sits beside this script; $LCARS_HOST_ADAPTER overrides the path so tests can
# stub the whole adapter. The adapter selects its host via $LCARS_HOST_BIN
# (default "github") and the github host shells out to ${LCARS_GH_BIN:-gh}.
HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SKILL_DIR/host-adapter.sh}"
host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@"; }
# The ADR-004 issue-comment mirror. Bundled beside this script; SOURCED (not
# shelled) so it reuses MISSION_DIR / json_raw / event_seen / emit_event / host.
# It defines render_comment (the ONE rendering, reused by S68) + mirror_comments
# (the best-effort, idempotent driver step that posts run progress to the issue).
# Sourcing only DEFINES functions — they are called later, after every helper
# they lean on is defined. $LCARS_COMMENT_MIRROR overrides the path for tests.
COMMENT_MIRROR="${LCARS_COMMENT_MIRROR:-$SKILL_DIR/comment-mirror.sh}"
# The SHARED renderer (ADR-004 "ONE rendering") — factored out of status.sh so
# the kanban card, `lcars status --watch`, AND the issue-comment mirror render
# the progress line / ticket data from the SAME primitives (compute_progress,
# ev_str, read_waves_totals, fmt_elapsed). The mirror leans on these, so source
# the shared lib BEFORE the mirror. render.sh provides a $LCARS_NOW-honouring
# now() (its guard skips if a now() already exists). $LCARS_RENDER_LIB overrides.
RENDER_LIB="${LCARS_RENDER_LIB:-$SKILL_DIR/../lcars-status/render.sh}"
[ -f "$RENDER_LIB" ] && . "$RENDER_LIB"
[ -f "$COMMENT_MIRROR" ] && . "$COMMENT_MIRROR"
# The cold-worker CLI adapter — the ONE place that knows a CLI's spawn flags and
# tool NAMES. This script (the stage driver) stays CLI-agnostic: it speaks a role
# keyword + a cli id (basename of WORKER_BIN) and delegates the actual one-shot to
# the adapter's `spawn`. $LCARS_WORKER_ADAPTER overrides the path so tests can stub
# it (same spirit as LCARS_GH_BIN / LCARS_HOST_ADAPTER). It sits beside this script.
WORKER_ADAPTER="${LCARS_WORKER_ADAPTER:-$SKILL_DIR/worker-adapter.sh}"
# The walk-away notification hook. The driver calls this ONCE at a human gate
# (awaiting-human or verify). Defaults to the bundled notify.sh; env-injectable
# (like LCARS_GH_BIN) so tests assert the call without sending anything.
NOTIFY_BIN="${LCARS_NOTIFY:-$SKILL_DIR/notify.sh}"
# S76 reconcile: the Mission Log scripts the self-heal routes through. Both are
# sibling skills after ./install.sh; env-injectable (like LCARS_PR_LIB) so tests
# can point a stub at them without touching the symlinks.
LOG_SCRIPT="${LCARS_LOG_SCRIPT:-$SKILL_DIR/../lcars-log/log.sh}"
RESOLVE_LOGS_SCRIPT="${LCARS_RESOLVE_LOGS_SCRIPT:-$SKILL_DIR/../lcars-resolve-logs/resolve-logs.sh}"
# A malformed worker output stops the Stage; the driver re-dispatches up to this
# many attempts before surfacing failure (no silent advance).
MAX_WORKER_TRIES="${LCARS_WORKER_TRIES:-3}"
# S98: a SHORTER bound for the EMPTY-worker case (a cold worker that produced
# NOTHING — empty stdout/stderr AND no files, the transient-CLI signal). A dead
# CLI should not burn the full attempt budget on long hang-guard timeouts: give
# it a couple of chances then escalate DISTINCTLY (see worker_produced_nothing).
MAX_EMPTY_WORKER_TRIES="${LCARS_EMPTY_WORKER_TRIES:-2}"
MAX_QUESTIONS=20
MAX_REVIEW_ROUNDS=3
RELABEL_NOTE=""
# The auto-advance summary rule.
SEP="─────────────────────────────────────────────"

die() { printf 'lcars run: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as file.sh / status.sh) ----------
json_str() { # file key  → first matching "key": "value"
  sed -En "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$1" \
    | head -1 \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}
json_raw() { # file key  → first matching bare token (number/null/bool)
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}
# --- a tiny NESTED/SCOPED reader (still jq-free, same sed/awk spirit) --------
# json_str/json_raw above are FLAT — they grab the FIRST matching key ANYWHERE in
# the file, so they cannot read `models.research` or `modelAliases.claude.opus`
# without risking a same-named key elsewhere. json_scoped_str narrows the search
# to a dotted PATH of object keys: each leading segment scopes into that object's
# `{ … }` body (brace-depth tracked so a nested object can't end the scope early),
# then the LAST segment is read as a string value within that final scope.
#   json_scoped_str FILE models.research        → the string at models.research
#   json_scoped_str FILE modelAliases.claude.opus
# Whitespace-insensitive (works for compact OR pretty JSON). Empty if any segment
# is absent. Reads strings only (the model tiers/aliases are all string values).
json_scoped_str() { # file dotted.path  → string value (or empty)
  local file="$1" path="$2"
  [ -f "$file" ] || return 0
  # Collapse the whole file to a single line so awk's char scan is brace-accurate
  # across pretty-printed (multi-line) JSON without newline bookkeeping.
  local blob; blob="$(tr -d '\n' <"$file")"
  # All but the last path segment scope IN; the last is the value key.
  local key="${path##*.}" parents="${path%.*}"
  if [ "$parents" != "$path" ]; then
    local seg
    local IFS='.'
    for seg in $parents; do
      blob="$(_json_scope_into "$blob" "$seg")"
      [ -n "$blob" ] || return 0
    done
  fi
  # Now read "key": "value" from the (possibly narrowed) blob, same decode as json_str.
  printf '%s' "$blob" \
    | sed -En "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" \
    | head -1 \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}
# Return the BODY (incl. braces) of the object value of "<key>": { … } within a
# single-line blob, matching braces so a nested object can't terminate it early.
_json_scope_into() { # blob key → "{ … }" body of that key's object value
  printf '%s' "$1" | awk -v key="$2" '
    {
      s = $0
      # locate the key token
      pat = "\"" key "\""
      idx = index(s, pat)
      if (idx == 0) { exit }
      rest = substr(s, idx + length(pat))
      # skip to the opening brace of its object value
      ob = index(rest, "{")
      if (ob == 0) { exit }
      rest = substr(rest, ob)
      depth = 0
      out = ""
      n = length(rest)
      for (i = 1; i <= n; i++) {
        c = substr(rest, i, 1)
        out = out c
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) break }
      }
      print out
    }'
}
# json_scoped_num — like json_scoped_str, but reads a NESTED NUMBER (or null) at a
# dotted path, e.g. tokenEstimates.research.low or copilot.opus.premiumRequestMultiplier.
# Scopes into each parent object's `{ … }` body (brace-accurate), then reads the
# last segment as a bare numeric token. Empty output if the path is absent OR the
# value is `null` (so callers can treat "" as "unavailable"). jq-free.
json_scoped_num() { # file dotted.path → number (or empty for absent/null)
  local file="$1" path="$2"
  [ -f "$file" ] || return 0
  local blob; blob="$(tr -d '\n' <"$file")"
  local key="${path##*.}" parents="${path%.*}"
  if [ "$parents" != "$path" ]; then
    local seg
    local IFS='.'
    for seg in $parents; do
      blob="$(_json_scope_into "$blob" "$seg")"
      [ -n "$blob" ] || return 0
    done
  fi
  local v
  v="$(printf '%s' "$blob" | sed -En "s/.*\"$key\"[[:space:]]*:[[:space:]]*([^,}[:space:]]+).*/\1/p" | head -1)"
  [ "$v" = "null" ] && v=""
  printf '%s' "$v"
}

# json_encode_string — emit a properly-escaped JSON STRING TOKEN (INCLUDING the
# surrounding double-quotes) for an arbitrary raw value. This is the SINGLE source
# of string escaping for the canonical estimate.json: every worker-derived string
# (rationale, each deviations[] entry, estimatorModel) is decoded by json_scoped_str
# then re-encoded through here, so quotes, newlines, tabs, backslashes and other
# control chars all round-trip as valid JSON instead of corrupting the file (S69).
#
# It delegates to a REAL encoder (python3, already a harness dependency) — never a
# hand-rolled printf — so the escaping is correct by construction. For a CLEAN
# string with no special chars, json.dumps produces EXACTLY `"<s>"`, byte-identical
# to the old `printf '"%s"'`, so a normal estimate stays byte-for-byte equivalent
# (no regression). The value arrives on STDIN so no argv quoting can mangle it; the
# trailing newline python emits is stripped so the token embeds inline cleanly.
json_encode_string() { # raw-string (via $1) → "escaped json string token"
  printf '%s' "$1" | "${LCARS_PYTHON_BIN:-python3}" -c \
    'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
}

# json_scoped_raw — like json_scoped_str but returns the string token's RAW
# (still-JSON-ESCAPED) body, WITHOUT any decoding. The caller can then FULLY and
# unambiguously decode it (json_decode_string) — important for fields like
# rationale where \n vs a literal backslash must not be conflated (the half-decode
# in json_scoped_str loses that distinction). jq-free; same brace-accurate scope.
json_scoped_raw() { # file dotted.path → raw escaped string body (or empty)
  local file="$1" path="$2"
  [ -f "$file" ] || return 0
  local blob; blob="$(tr -d '\n' <"$file")"
  local key="${path##*.}" parents="${path%.*}"
  if [ "$parents" != "$path" ]; then
    local seg
    local IFS='.'
    for seg in $parents; do
      blob="$(_json_scope_into "$blob" "$seg")"
      [ -n "$blob" ] || return 0
    done
  fi
  printf '%s' "$blob" \
    | sed -En "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" \
    | head -1
}

# json_decode_string — fully decode a RAW JSON string body (the chars BETWEEN the
# quotes, e.g. from json_scoped_raw) into its literal value: \n→newline, \t→tab,
# \\→\, \"→", \uXXXX→char. Uses the real JSON parser so the decode is exact.
json_decode_string() { # raw-escaped-body (via $1) → literal string
  printf '%s' "$1" | "${LCARS_PYTHON_BIN:-python3}" -c \
    'import json,sys; sys.stdout.write(json.loads("\"" + sys.stdin.read() + "\""))' 2>/dev/null
}

# --- tiny JSON writers (pretty, one-field-per-line state.json) --------------
# state.json is written one field per line (see file.sh), so we edit it by the
# line. New fields are inserted right after the opening brace — always valid
# because `id` always follows. Untrusted text (question text) is JSON-escaped
# and handed to awk via the environment so awk never reinterprets its escapes.
json_escape() { # string → JSON-string-safe (printed, no surrounding quotes)
  # Backslash and double-quote first via fast bash substitution; then hand the
  # result to awk to escape EVERY control character (0x00–0x1F) — newline, tab,
  # carriage-return get their short forms (\n \t \r), the rest become \u00XX —
  # so ANY worker-derived text (e.g. a multi-line reconcileDiagnosis) yields
  # VALID JSON. jq-free, in the house style. Order matters: backslash first so
  # the escapes we add below are not themselves re-escaped.
  local s="$1"
  s="${s//\\/\\\\}"   # backslashes first…
  s="${s//\"/\\\"}"   # …then double-quotes
  # awk does the control-character pass. RS="" + reading the whole record keeps
  # embedded newlines; we walk byte by byte so we never depend on locale.
  printf '%s' "$s" | awk '
    BEGIN {
      RS="\034"; ORS=""              # record sep that cannot appear in our text
      # MAP holds the bytes with codes 1..31; index() is 1-based so the position
      # of a byte in MAP IS its character code. NUL (0x00) cannot reach us
      # through a bash variable, so it need not be mapped.
      MAP = ""
      for (k = 1; k < 32; k++) MAP = MAP sprintf("%c", k)
    }
    {
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if      (c == "\n") printf "\\n"
        else if (c == "\t") printf "\\t"
        else if (c == "\r") printf "\\r"
        else { b = index(MAP, c)      # other 0x01–0x1F → \u00XX, else verbatim
               if (b > 0) printf "\\u%04x", b; else printf "%s", c }
      }
    }
  '
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
  # --git-common-dir (NOT --git-dir): from inside a `git worktree` the plain
  # --git-dir is the per-worktree `.git/worktrees/<wt>` dir, but the Mission's
  # artifacts (state, tickets, events) live in the SHARED `.git/lcars`. The
  # common dir is that shared `.git` in both a normal checkout AND a worktree, so
  # a per-ticket worktree (Session 37) resolves the SAME mission dir as $REPO_ROOT.
  gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" \
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
  local pack="$1" scratch out prompt
  mkdir -p "$(dirname "$pack")"
  scratch="$(mktemp -d)"
  out="$scratch/context-pack.md"
  prompt="$(cat "$STAGES_DIR/context-pack.md")

You MAY first read whatever you need, but you MUST then create your context pack
file on disk with your file-creation / file-writing tool (that tool IS available
to you here). Create it ONCE, with its COMPLETE final content, in a single write —
do NOT create an empty or placeholder file intending to fill it in later, because
your file-creation tool may not support overwriting a file that already exists.
You MUST create the file — with its full final content — BEFORE you end your turn.
Do NOT end your turn by announcing what you will do; describing the task is NOT
doing it. Your turn is NOT complete until the file exists on disk. The harness
reads ONLY that file, never your reply; a reply-only answer counts as no output
and FAILS. Create that one file and nowhere else, at the path on the next line:
Write your context pack to EXACTLY: $out"
  # Same toolset as a repo-read Stage, but the worker must see
  # LCARS_WORKER_ROLE=context-pack (toolset-role and env-role differ here). Pre-
  # export the env-role; pass repo-read as the adapter's TOOLSET role — the adapter
  # does not overwrite an already-set LCARS_WORKER_ROLE, preserving both exactly.
  LCARS_WORKER_ROLE="context-pack" worker_spawn repo-read "$scratch" "$prompt"
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

# Resolve the mission's durable image attachments (staged at File / Mission-Log
# time under $MISSION_DIR/attachments/) into a block of ABSOLUTE paths appended
# to a cold Stage's `extra`, so the Research/Validate/Plan/Implement workers READ
# the captain's screenshots BY PATH (the S91 spike proved cold-stage
# Read-image-by-path works for both engines; a path is sufficient). MIRRORS
# context_extra_block, but globs the attachments dir directly so it is robust —
# independent of state.json. Returns EMPTY when the dir is absent or empty, so a
# no-attachment mission's prompt is byte-identical to before.
attachments_extra_block() {
  local d="$MISSION_DIR/attachments" f any=0 out=""
  [ -d "$d" ] || return 0
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    if [ "$any" -eq 0 ]; then
      out='
## Attached images (the captain attached these; view/read them as part of your input)'
      any=1
    fi
    out="$out
- $f"
  done
  [ "$any" -eq 1 ] && printf '%s' "$out"
  return 0
}

# The branch that anchors this Mission's code. For a full Mission it is the base
# branch the work builds on (recorded at File time); for a logged bug it equals
# the parent's delivered branch (the code the fix targets). The four read-only
# stages (Research questions, Validate, Plan, Plan Review) spawn a repo-read
# worker whose cwd is the AMBIENT working-tree checkout — which may be sitting on
# an UNRELATED branch. That is the cross-mission "reason leak": a bug filed while
# the tree was on a sibling Copilot branch had its Validate worker `git log` that
# CHECKED-OUT branch, decide the feature was "already fixed" by that lineage, and
# OVERRIDE the correct grounding. Naming the Mission's OWN branch here pins every
# such worker to the right code (mirrors research-grounding's "Where the delivered
# code lives" block). Returns EMPTY when no branch is recorded, so a mission
# without one produces a byte-identical prompt to before.
mission_branch_block() {
  local b; b="$(json_str "$STATE" branch)"
  [ -n "$b" ] || return 0
  printf '

## Which code to read — READ THIS
The code for this Mission lives on branch `%s`. When you inspect the
repository, inspect THAT branch (e.g. `git show %s:<path>`, `git log %s`)
— it holds the implementation this Mission is reasoning about. The working-tree
checkout may be on an UNRELATED branch; IGNORE it and its history. Do not draw
conclusions from, or defer to, any other Mission'\''s branch or commits.' "$b" "$b" "$b"
}

# === Per-wave repo map (pure bash, token-free, CLI-neutral) =================
# A SYMBOL SKELETON of the repo's source: top-level interface SIGNATURES
# (function / method / class / def / type / interface / export / shell-func
# declarations) keyed off each file's extension, plus the bare path of any file
# whose type we don't recognise. SKELETONS ONLY — signature lines + paths, NEVER
# a function body or a statement from inside one. It is a navigation aid, not a
# compiler: simple grep/sed heuristics, deterministic, fast, robust to many
# languages, degrading gracefully (path alone) for unknown types.
#
# Written to $MISSION_DIR/repo-map.md — inside .git/, never the working tree. It
# is REGENERATED at the start of each Implement wave (so wave N sees wave N-1's
# committed symbols), carrying the wave label in its header so a fresh
# regeneration is observable. The static context-pack.md remains the
# architecture/conventions layer; this is the fresh symbol layer on top.
#
# Args: <repo-root> <out-file> [<wave-label>]
generate_repo_map() {
  local root="$1" out="$2" wave="${3:-}"
  mkdir -p "$(dirname "$out")"
  {
    printf '# Repo map'
    [ -n "$wave" ] && printf ' (%s)' "$wave"
    printf '\n\n'
    printf 'A symbol skeleton of the repo source — interface SIGNATURES and file\n'
    printf 'PATHS only, NO bodies. A navigation aid: read the file itself for detail.\n\n'
  } >"$out"

  # Enumerate tracked + untracked source files (git ls-files keeps us inside the
  # repo and honours .gitignore), falling back to find when git is unavailable.
  local files
  files="$("$GIT_BIN" -C "$root" ls-files --cached --others --exclude-standard 2>/dev/null)"
  [ -n "$files" ] || files="$(cd "$root" && find . -type f 2>/dev/null | sed 's|^\./||')"

  local f ext
  # Sort for deterministic output.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Never descend into VCS / dependency / build noise — and never the mission
    # state itself (it lives under .git, already excluded, but be explicit).
    case "$f" in
      .git/*|*/.git/*|node_modules/*|*/node_modules/*|.git|vendor/*|*/vendor/*|dist/*|build/*) continue ;;
    esac
    [ -f "$root/$f" ] || continue
    ext="${f##*.}"
    case "$ext" in
      sh|bash|zsh)
        # POSIX shell function declarations: `name()` or `function name`.
        printf '## %s\n' "$f" >>"$out"
        grep -nE '^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_:-]*[[:space:]]*\(\)|function[[:space:]]+[a-zA-Z_])' "$root/$f" 2>/dev/null \
          | sed -E 's/[[:space:]]*\{[[:space:]]*$//' \
          | sed -E 's/^([0-9]+):[[:space:]]*/- L\1: /' >>"$out" || true
        printf '\n' >>"$out" ;;
      js|jsx|ts|tsx|mjs|cjs)
        printf '## %s\n' "$f" >>"$out"
        # function / class / interface / type / const-arrow / export declarations
        # — the DECLARATION line only, with any trailing `{` body-opener stripped.
        grep -nE '^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function[*]?[[:space:]]|class[[:space:]]|interface[[:space:]]|type[[:space:]]|enum[[:space:]]|const[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=[[:space:]]*(async[[:space:]]*)?\()' "$root/$f" 2>/dev/null \
          | sed -E 's/[[:space:]]*\{[[:space:]]*$//' \
          | sed -E 's/^([0-9]+):[[:space:]]*/- L\1: /' >>"$out" || true
        printf '\n' >>"$out" ;;
      py)
        printf '## %s\n' "$f" >>"$out"
        # top-level + nested def / class declarations — the signature line up to
        # the `:` that opens the body (the body itself is on following lines).
        grep -nE '^[[:space:]]*(async[[:space:]]+)?(def|class)[[:space:]]' "$root/$f" 2>/dev/null \
          | sed -E 's/:[[:space:]]*$//' \
          | sed -E 's/^([0-9]+):[[:space:]]*/- L\1: /' >>"$out" || true
        printf '\n' >>"$out" ;;
      go)
        printf '## %s\n' "$f" >>"$out"
        grep -nE '^[[:space:]]*(func|type)[[:space:]]' "$root/$f" 2>/dev/null \
          | sed -E 's/[[:space:]]*\{[[:space:]]*$//' \
          | sed -E 's/^([0-9]+):[[:space:]]*/- L\1: /' >>"$out" || true
        printf '\n' >>"$out" ;;
      rb)
        printf '## %s\n' "$f" >>"$out"
        grep -nE '^[[:space:]]*(def|class|module)[[:space:]]' "$root/$f" 2>/dev/null \
          | sed -E 's/^([0-9]+):[[:space:]]*/- L\1: /' >>"$out" || true
        printf '\n' >>"$out" ;;
      *)
        # Unknown type → degrade gracefully: list the path alone, no signatures
        # (we never dump unrecognised file contents — that could leak a body).
        printf '## %s\n\n' "$f" >>"$out" ;;
    esac
  done < <(printf '%s\n' "$files" | LC_ALL=C sort)
}

# `run.sh repo-map --mission <id>` — the thin, token-free driver over
# generate_repo_map: resolve the mission + repo root, regenerate the map. Public
# so it is independently testable; cmd_implement calls generate_repo_map directly
# at each wave_start (with a wave label).
cmd_repo_map() {
  locate_mission "$MISSION_ID"
  generate_repo_map "$REPO_ROOT" "$MISSION_DIR/repo-map.md"
  echo "REPO-MAP: wrote $MISSION_DIR/repo-map.md"
}

# A block listing the per-ticket manifest + per-wave repo map for the Implement
# pair — by PATH only, guarded on existence. NEVER called from Research. Args:
# <ticket-id>. Echoes nothing when neither artifact exists.
implement_nav_block() { # ticket-id
  local tid="$1" block=""
  [ -f "$MISSION_DIR/manifests/$tid.md" ] && block="$block
- $MISSION_DIR/manifests/$tid.md   (this ticket's context manifest — relevant files + interface signatures + touched ADR ids; NAVIGATION ONLY, not the implementation. The Test Writer uses the listed files to find the PUBLIC INTERFACE to test against — NOT as a place to add tests into; always write a dedicated fail-first test file.)"
  [ -f "$MISSION_DIR/repo-map.md" ] && block="$block
- $MISSION_DIR/repo-map.md   (the repo symbol map — interface signatures + paths across the codebase, regenerated this wave; navigate from it instead of cold file-walking)"
  printf '%s' "$block"
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

  # A LOGGED bug runs Research in grounding mode (cmd_research short-circuits to
  # cmd_research_grounding before ever calling this gate), so a bug should never
  # reach the >MAX escalation. Belt-and-braces: if a bug ever DOES hit the gate,
  # it can NEVER escalate to awaiting-human from Research — treat any count as a
  # plain dispatch (no awaitingHuman flag is ever set for a bug here).
  local g_origin g_type
  g_origin="$(json_str "$STATE" origin)"
  g_type="$(json_str "$STATE" type)"
  if { [ "$g_origin" = "log" ] || [ "$g_type" = "bug" ]; } && [ "$n" -gt "$MAX_QUESTIONS" ]; then
    echo "GATE: dispatch $n"
    echo "  Logged bug — grounding mode never escalates; dispatching $n agent(s)."
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
    # BUG-027: structured, legible escalation fields the viewscreen consumes. They
    # are OPTIONAL — only emitted when the caller exports them — so every existing
    # gate (no fields set) writes byte-identical pending.json as before, preserving
    # back-compat. When present they sit ALONGSIDE the raw question text (never
    # replacing it): humanSummary (plain-language, GitHub-issue language — no
    # internal t-XXX ids), escalationType (regression|scope|cap so the UI picks
    # type-appropriate copy), and technicalDetail (the raw reason + command,
    # verbatim, where the internal ids may remain).
    [ -n "${LCARS_PENDING_HUMAN_SUMMARY:-}" ] && \
      printf '  "humanSummary": "%s",\n' "$(json_escape "$LCARS_PENDING_HUMAN_SUMMARY")"
    [ -n "${LCARS_PENDING_ESCALATION_TYPE:-}" ] && \
      printf '  "escalationType": "%s",\n' "$(json_escape "$LCARS_PENDING_ESCALATION_TYPE")"
    [ -n "${LCARS_PENDING_TECHNICAL_DETAIL:-}" ] && \
      printf '  "technicalDetail": "%s",\n' "$(json_escape "$LCARS_PENDING_TECHNICAL_DETAIL")"
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
      inobj=1; delete have; acok=0; id=""; ndep=0; in_ac=0; next
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
    # Inside a MULTI-LINE acceptanceCriteria array (canonical shape is inline, but
    # a worker that pretty-prints the array across lines is still valid): count any
    # non-empty quoted string as a satisfied criterion, and close the array on its
    # `]`. Runs BEFORE the generic key parser so criterion text never pollutes have[].
    inobj && in_ac {
      m=split($0, b, "\"")
      for (i=2; i<m; i+=2) if (b[i] != "") acok=1
      if ($0 ~ /\]/) in_ac=0
      next
    }
    inobj {
      n=split($0, a, "\"")          # inside-quote contents land at even indices
      if (n < 2) next
      key=a[2]; have[key]=1
      if (key=="id") id=a[4]
      else if (key=="acceptanceCriteria") {
        if (n >= 4) acok=1          # inline ["a", …] — criterion text on this line
        if ($0 !~ /\]/) in_ac=1     # array opens here, closes on a later line
      }
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

  # Session 41: the Plan worker ALSO emits one context manifest per ticket into a
  # `manifests/` dir alongside plan.json in its scratch output. Persist them into
  # the mission dir (SEPARATE files — never embedded in plan.json, whose awk
  # parser would break on a nested object). BEST-EFFORT: a missing manifest must
  # NOT hard-fail the plan (single-ticket fast-path, thin greenfield slices) — the
  # template requires one per ticket, but persistence only copies what exists.
  if [ -n "$MANIFESTS" ] && [ -d "$MANIFESTS" ]; then
    rm -rf "$MISSION_DIR/manifests"
    mkdir -p "$MISSION_DIR/manifests"
    local mf
    for mf in "$MANIFESTS"/*.md; do
      [ -f "$mf" ] && cp "$mf" "$MISSION_DIR/manifests/"
    done
  fi

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

# --- inline a single ticket's spec for the Test Writer's cold handoff --------
# Session 22 (BUG-003 fallout): a cold worker handed ONLY a PATH to
# approved-plan.json + the ticket id can ground on the wrong artifact (CONTEXT.md)
# and fabricate a plausible-but-wrong feature. Strengthen the handoff by inlining
# THIS ticket's title + description + acceptanceCriteria TEXT into the prompt — in
# ADDITION to the path, never instead of it. CLI-AGNOSTIC: lives in the shared
# stage-prompt assembly, identical for every worker CLI; no per-CLI branch.
# Reuses parse_plan_table (the same jq-free parse the rest of run.sh uses) so no
# new JSON dependency. Degrades gracefully: a missing title/description/criteria
# line is simply omitted; a ticket absent from the plan yields an empty block, so
# the existing "$TICKET" id line still carries the handoff and the stage never
# breaks. Echoes a block to be appended under "## Your ticket".
ticket_spec_block() { # plan-file ticket-id
  local plan="$1" id="$2" line title desc crit block=""
  [ -f "$plan" ] || return 0
  line="$(parse_plan_table "$plan" 2>/dev/null | awk -F'\t' -v want="$id" '$1==want{print; exit}')"
  [ -n "$line" ] || return 0
  title="$(printf '%s' "$line" | cut -f2)"
  desc="$(printf '%s' "$line" | cut -f3)"
  crit="$(printf '%s' "$line" | cut -f4)"
  # Header: "<id> — <title>" when a title exists, else just the id.
  if [ -n "$title" ]; then block="$id — $title"; else block="$id"; fi
  [ -n "$desc" ] && block="$block
$desc"
  if [ -n "$crit" ]; then
    block="$block

Acceptance criteria (write failing tests for EXACTLY this behaviour):
$(printf '%s' "$crit" | awk -F' \\| ' '{ for (i=1;i<=NF;i++) printf "- %s\n", $i }')"
  fi
  printf '%s' "$block"
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

# --- the package a ticket's code lives in (S87, monorepo gate staging) -------
# A monorepo gate cannot stage the quarantined suite at a DEPTH-1 dir under the
# REPO ROOT and run the runner there: vitest/jest DISCOVER and FILTER tests
# RELATIVE to a PACKAGE root, and the quarantined tests import package-relative
# sources (`import {x} from "../src/y"`). Staged at the wrong root the runner finds
# "No test files" and a correct implementation RED-fails the gate. So when a
# ticket's code lives in a sub-package we stage the quarantine INSIDE that package
# and run the runner FROM it. This helper names that package.
#
# It reads the ticket's manifest ($MISSION_DIR/manifests/<id>.md), parses the
# `## Relevant files` bullet list (`- <path>`, backticks/whitespace tolerated), and
# for each listed path walks UP to the nearest ancestor dir D (D != ".") where
# `<root>/D/package.json` exists. <root> defaults to $REPO_ROOT and is the tree the
# package.json existence is checked against, so a gate checks its OWN worktree.
# Echoes the single distinct D RELATIVE to the repo root (e.g. `packages/core`), or
# "" when: the code sits at the repo root / no sub-package.json is found (0
# candidates), the files SPAN multiple packages (>1 candidate), or the manifest is
# missing. Every "" case routes the gate through TODAY'S byte-for-byte repo-root
# behaviour — a safe no-op.
ticket_target_package() { # ticketId [root]  → pkg dir relative to repo root, or ""
  local id="$1" root="${2:-$REPO_ROOT}"
  local mf="$MISSION_DIR/manifests/$id.md"
  [ -f "$mf" ] || return 0
  local found="" path d cand
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # Walk UP from the listed path to the nearest ancestor dir holding a
    # package.json. The path itself is tried first (it may BE a package dir).
    d="$path"; cand=""
    while [ -n "$d" ] && [ "$d" != "." ]; do
      if [ -f "$root/$d/package.json" ]; then cand="$d"; break; fi
      case "$d" in */*) d="${d%/*}" ;; *) d="." ;; esac
    done
    [ -n "$cand" ] || continue
    case " $found " in *" $cand "*) : ;; *) found="${found:+$found }$cand" ;; esac
  done <<EOF
$(manifest_relevant_files "$mf")
EOF
  # 0 candidates → "" (root / no sub-package); exactly 1 → it; >1 (spans packages) → "".
  set -- $found
  [ "$#" -eq 1 ] || return 0
  printf '%s' "$1"
}

# --- parse a manifest's `## Relevant files` bullet paths --------------------
# Emits one path per line. Reads only the `## Relevant files` section, tolerates
# `-`/`*` bullets, backtick-wrapped paths, a trailing ` — description`, and a
# leading `./`. Used by ticket_target_package; jq-free, awk-only.
manifest_relevant_files() { # manifest-file → one path per line
  awk '
    /^##[[:space:]]+[Rr]elevant[[:space:]]+files/ { ins=1; next }
    /^##[[:space:]]/                              { ins=0 }
    ins && /^[[:space:]]*[-*][[:space:]]+/ {
      line=$0
      sub(/^[[:space:]]*[-*][[:space:]]+/, "", line)  # strip the bullet marker
      gsub(/`/, "", line)                              # strip backticks
      n=split(line, a, /[[:space:]]+/)                 # first token = the path
      if (n>0 && a[1] != "") { p=a[1]; sub(/^\.\//, "", p); sub(/\/+$/, "", p); if (p!="") print p }
    }
  ' "$1" 2>/dev/null
}

# === S101 (tests ride along, part 1): in-tree test convention =================
# The Test-Writer's per-ticket fail-first test should land IN THE REPO at the
# repo's OWN test convention (co-located `foo.test.ts`, a `__tests__/` dir, or a
# top-level `tests/` dir) rather than only in the `.git/lcars` quarantine — so the
# red gate + the Implementer run it IN PLACE (co-located `./sibling` imports
# resolve) and a later session can commit it by path. These two functions are
# PURE (filesystem read only — NO execution, NO network) and hook-testable.

# --- detect_test_convention: infer the repo's test-file convention -----------
# Walks the repo for EXISTING tests and picks the convention nearest the target
# source path. Echoes exactly one of: co-located | __tests__ | tests. A TS/JS repo
# with NO existing tests DEFAULTS to co-located. node_modules and .git are skipped.
detect_test_convention() { # repo_root  target_src_path
  local root="$1" target="${2:-}"
  local tdir=""; case "$target" in */*) tdir="${target%/*}" ;; *) tdir="" ;; esac

  # 1) NEAREST-to-target: a sibling *.test.*/*.spec.* in the target's OWN dir is the
  #    strongest co-located signal; a sibling __tests__/ dir the strongest __tests__.
  if [ -n "$tdir" ] && [ -d "$root/$tdir" ]; then
    if find "$root/$tdir" -maxdepth 1 -type f \( -name '*.test.*' -o -name '*.spec.*' \) \
         -print -quit 2>/dev/null | grep -q .; then
      printf 'co-located'; return 0
    fi
    if [ -d "$root/$tdir/__tests__" ]; then printf '__tests__'; return 0; fi
  fi

  # 2) Repo-wide fallback. A co-located test anywhere (outside __tests__/ and a
  #    top-level tests/) wins; else any __tests__/ dir; else a populated top-level
  #    tests/; else — no existing tests — default co-located.
  if find "$root" \
       \( -path '*/.git' -o -path '*/node_modules' -o -path '*/__tests__' -o -path '*/tests' \) -prune -o \
       -type f \( -name '*.test.*' -o -name '*.spec.*' \) -print 2>/dev/null \
       | head -1 | grep -q .; then
    printf 'co-located'; return 0
  fi
  if find "$root" -type d -name '__tests__' \
       ! -path '*/.git/*' ! -path '*/node_modules/*' -print -quit 2>/dev/null | grep -q .; then
    printf '__tests__'; return 0
  fi
  if [ -d "$root/tests" ] && find "$root/tests" -type f \
       \( -name '*.test.*' -o -name '*.spec.*' -o -name 'test_*' -o -name '*_test.*' \) \
       -print -quit 2>/dev/null | grep -q .; then
    printf 'tests'; return 0
  fi
  printf 'co-located'
}

# --- test_path_for: map a target SOURCE path → the in-tree TEST relpath -------
# Preserves the source extension family (.ts/.tsx/.js/.jsx/.mts/.cts/.mjs/.cjs;
# default .ts when the source has no extension).
#   co-located → a/b/foo.ts → a/b/foo.test.ts
#   __tests__  → a/b/foo.ts → a/b/__tests__/foo.test.ts
#   tests      → a/b/foo.ts → tests/foo.test.ts
test_path_for() { # convention  target_src_path
  local conv="$1" src="$2" dir base ext stem
  case "$src" in */*) dir="${src%/*}" ;; *) dir="" ;; esac
  base="${src##*/}"
  case "$base" in
    *.*) ext="${base##*.}"; stem="${base%.*}" ;;
    *)   ext="ts"; stem="$base" ;;
  esac
  case "$conv" in
    __tests__) printf '%s%s__tests__/%s.test.%s' "$dir" "${dir:+/}" "$stem" "$ext" ;;
    tests)     printf 'tests/%s.test.%s' "$stem" "$ext" ;;
    *)         printf '%s%s%s.test.%s' "$dir" "${dir:+/}" "$stem" "$ext" ;;
  esac
}

# --- ticket_target_src: the ticket's primary SOURCE path (for convention) ----
# 1) the first source-looking path in the manifest's `## Relevant files` (skips
#    test/spec files and test dirs); 2) fallback — infer from the greenfield
#    sibling the Test-Writer's suite imports (a strong signal for a brand-new
#    module). Echoes a repo-relative source path, or "" when nothing is derivable.
ticket_target_src() { # ticketId  [tests-dir]  → source relpath or ""
  local mf="$MISSION_DIR/manifests/$1.md" p
  if [ -f "$mf" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in *.test.*|*.spec.*|*/__tests__/*|tests/*) continue ;; esac
      case "$p" in
        *.ts|*.tsx|*.js|*.jsx|*.mts|*.cts|*.mjs|*.cjs) printf '%s' "$p"; return 0 ;;
      esac
    done <<EOF
$(manifest_relevant_files "$mf")
EOF
  fi
  local tdir="${2:-}" spec norm
  if [ -n "$tdir" ] && [ -d "$tdir" ]; then
    spec="$(grep -rhoE "(from|import|require\()[[:space:]]*['\"][^'\"]+['\"]" "$tdir" 2>/dev/null \
             | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" \
             | grep -E '^[.]' | head -1)"
    if [ -n "$spec" ]; then
      norm="${spec#./}"
      while case "$norm" in ../*) true ;; *) false ;; esac; do norm="${norm#../}"; done
      case "$norm" in *.*) : ;; *) norm="$norm.ts" ;; esac
      printf '%s' "$norm"; return 0
    fi
  fi
  return 0
}

# === S101 (tests ride along) — MULTI-FILE / MULTI-DIR co-located placement ====
# The Test-Writer for one ticket can author SEVERAL test files whose target sources
# live in DIFFERENT dirs (e.g. a greenfield `src/utils/isDefaultViewport.ts`, an
# existing `src/canvas/editorCanvas.ts`, and a `src/components/MapCanvas/MapCanvas.tsx`).
# Each test must land co-located NEXT TO ITS OWN source so its `./<sibling>` import
# resolves in place; placing them all in one dir (the first target's) breaks every
# import but the first. These PURE helpers derive each file's own destination and the
# common scope for the in-place red gate. Filesystem read only — NO execution.

# --- test_primary_sibling: the module-under-test a test file imports ----------
# Scans a test file's RELATIVE (`./…` / `../…`) import specifiers and echoes the STEM
# of its primary module-under-test: PREFER the relative import whose basename stem
# equals the test's OWN stem (`editorCanvas.test.ts` → `./editorCanvas`), else the
# FIRST relative import. Echoes "" when the file has no relative import (the caller
# falls back to the ticket's primary source). Nested paths degrade to the basename.
test_primary_sibling() { # test-file → sibling stem or ""
  local f="$1" base tstem spec sb first=""
  base="${f##*/}"; base="${base%.*}"                 # drop the file extension
  case "$base" in *.test) tstem="${base%.test}" ;; *.spec) tstem="${base%.spec}" ;; *) tstem="$base" ;; esac
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    sb="${spec##*/}"; case "$sb" in *.*) sb="${sb%.*}" ;; esac   # last segment, drop any ext
    [ -n "$sb" ] || continue
    [ -z "$first" ] && first="$sb"
    [ "$sb" = "$tstem" ] && { printf '%s' "$sb"; return 0; }
  done <<EOF
$(grep -hoE "(from|import|require\()[[:space:]]*['\"][^'\"]+['\"]" "$f" 2>/dev/null \
   | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" | grep -E '^[.]')
EOF
  printf '%s' "$first"
}

# --- resolve_sibling_src: a co-located sibling STEM → its in-tree SOURCE path --
# So a per-file placement can co-locate the test next to the real source:
#   1) MANIFEST match — a `## Relevant files` SOURCE path (skips test/spec files)
#      whose basename stem equals STEM (any source ext). Covers existing sources AND
#      greenfield ones the ticket DECLARES (e.g. a new isDefaultViewport.ts).
#   2) PACKAGE/REPO search — find <STEM>.<ext> under the ticket's package (or the
#      whole repo) for a source not named in the manifest.
#   3) FALLBACK — a truly novel greenfield not in the manifest: use $fallback_src
#      (the ticket's primary target source) so the test co-locates in the ticket's
#      primary source dir, byte-identical to the pre-multi-dir single-dir behaviour.
# $prune (5th arg, newline-separated ABS dirs) are input scratch dirs to NEVER resolve
# into — the worker's tests/ + stubs/ scratch dirs (a mktemp OUTSIDE the repo in real
# use, so the repo-wide search never sees them; pruned explicitly so a fixture that
# nests them under the repo still resolves the sibling to the real in-tree source, not
# a copy of the test/stub). Echoes a repo-relative source path (never "" for a STEM).
resolve_sibling_src() { # stem  ticketId  fallback_src  [pkg_rel]  [prune] → source relpath
  local stem="$1" tid="$2" fallback="$3" pkg="${4:-}" prune="${5:-}"
  [ -n "$stem" ] || { printf '%s' "$fallback"; return 0; }
  local mf="$MISSION_DIR/manifests/$tid.md" p pb
  if [ -f "$mf" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in *.test.*|*.spec.*|*/__tests__/*|tests/*) continue ;; esac
      case "$p" in *.ts|*.tsx|*.js|*.jsx|*.mts|*.cts|*.mjs|*.cjs) : ;; *) continue ;; esac
      pb="${p##*/}"; pb="${pb%.*}"
      [ "$pb" = "$stem" ] && { printf '%s' "$p"; return 0; }
    done <<EOF
$(manifest_relevant_files "$mf")
EOF
  fi
  local root hit skip pd
  for root in ${pkg:+"$REPO_ROOT/$pkg"} "$REPO_ROOT"; do
    [ -d "$root" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      skip=no
      while IFS= read -r pd; do
        [ -n "$pd" ] || continue
        case "$hit" in "$pd"/*) skip=yes; break ;; esac
      done <<PRUNE
$prune
PRUNE
      [ "$skip" = yes ] && continue
      printf '%s' "${hit#"$REPO_ROOT"/}"; return 0
    done <<EOF
$(find "$root" \( -path '*/.git' -o -path '*/node_modules' \) -prune -o \
     -type f \( -name "$stem.ts" -o -name "$stem.tsx" -o -name "$stem.js" \
     -o -name "$stem.jsx" -o -name "$stem.mts" -o -name "$stem.cts" \
     -o -name "$stem.mjs" -o -name "$stem.cjs" \) -print 2>/dev/null \
   | grep -vE '\.(test|spec)\.' | LC_ALL=C sort)
EOF
  done
  printf '%s' "$fallback"
}

# --- common_ancestor_dir: deepest shared parent DIR of a set of relpaths -------
# Given newline-separated repo-relative paths, echoes the deepest directory that is a
# leading path-segment prefix of EVERY path's dir ("" = repo root). Used to scope the
# in-place red gate when a ticket's placed test files span more than one dir.
common_ancestor_dir() { # <newline relpaths> → common dir ("" = root)
  local rels="$1"
  printf '%s\n' "$rels" | awk '
    { if ($0=="") next
      dir=$0; sub(/\/[^\/]*$/, "", dir); if (dir==$0) dir=""     # dirname
      if (!seen) { common=dir; seen=1; next }
      n=split(common,C,"/"); m=split(dir,D,"/"); k=(n<m)?n:m; out=""
      for (i=1;i<=k;i++){ if (C[i]==D[i]) out=(out=="")?C[i]:out"/"C[i]; else break }
      common=out
    }
    END { if (seen) print common }'
}

# === Plan Review: SOFT under-slice signal (S100) ============================
# Plan Review kept passing a MEGA-ticket that hid a whole surface behind a simple
# title (the "migrate all the chrome to tokens" ticket that silently left App.tsx
# / the Toolbar unscoped). slice_pressure is a HEURISTIC HINT that helps the
# reviewer notice such an under-slice. It is SIGNAL ONLY: it NEVER changes the
# accept/reject verdict, never `die`s, never exits nonzero on pressure — the
# reviewer LLM still decides. The mechanical validator (validate_plan_json) is
# untouched; the budget stays a PLANNING TARGET.

# --- slice_pressure: one ticket's under-slice pressure from its OWN fields ---
# Inputs (all from a ticket's DECLARED fields): number of distinct acceptance
# criteria, number of files it touches + distinct dirs (from its manifest's
# "Relevant files"; 0/0 when no manifest — degrade gracefully), and
# estimatedNewLoc vs comprehensionBudget. Echoes "<level>\t<reason>" where level
# is low|elevated|high. A simple additive score over the four signals; level
# thresholds: score>=4 high, >=2 elevated, else low.
#
# CRITICAL (budget-is-a-target): the LoC signal is estimatedNewLoc — the
# IMPLEMENTATION weight — NOT estimatedReadLoc. A ticket that is over budget only
# because it must READ one big existing file carries a small newLoc, so it never
# reads as high pressure. That is exactly the case the design note protects.
slice_pressure() { # nCriteria nFiles nDirs newLoc budget -> "<level>\t<reason>"
  local nc="${1:-0}" nf="${2:-0}" nd="${3:-0}" newloc="${4:-0}" budget="${5:-1200}"
  nc=$((nc + 0)); nf=$((nf + 0)); nd=$((nd + 0)); newloc=$((newloc + 0)); budget=$((budget + 0))
  [ "$budget" -gt 0 ] || budget=1200
  local score=0
  # acceptance-criteria breadth — many distinct criteria hint at bundled behaviors.
  if   [ "$nc" -ge 5 ]; then score=$((score + 2))
  elif [ "$nc" -ge 3 ]; then score=$((score + 1)); fi
  # file breadth — many touched files hint at a wide surface (secondary; 0 = no manifest).
  if   [ "$nf" -ge 6 ]; then score=$((score + 2))
  elif [ "$nf" -ge 3 ]; then score=$((score + 1)); fi
  # directory breadth — spread across dirs hints at multiple layers/areas.
  if   [ "$nd" -ge 3 ]; then score=$((score + 2))
  elif [ "$nd" -ge 2 ]; then score=$((score + 1)); fi
  # implementation weight — estimatedNewLoc (NOT read) vs the planning target.
  local loc_rel
  if [ "$newloc" -gt "$budget" ]; then
    score=$((score + 2)); loc_rel="estimatedNewLoc $newloc > budget $budget"
  elif [ $((newloc * 4)) -gt $((budget * 3)) ]; then
    score=$((score + 1)); loc_rel="estimatedNewLoc $newloc near budget $budget"
  else
    loc_rel="estimatedNewLoc $newloc <= budget $budget"
  fi
  local level=low
  if   [ "$score" -ge 4 ]; then level=high
  elif [ "$score" -ge 2 ]; then level=elevated; fi
  printf '%s\t%d criteria, %d file(s) across %d dir(s); %s' \
    "$level" "$nc" "$nf" "$nd" "$loc_rel"
}

# --- per-ticket rows for the hint: id \t title \t criteriaCount \t newLoc -----
# jq-free awk over the canonical one-field-per-line plan.json shape (inline OR
# multi-line acceptanceCriteria), mirroring validate_plan_json's object parse.
slice_pressure_rows() { # plan.json
  awk '
    /^[[:space:]]*\{[[:space:]]*$/ { inobj=1; id=""; title=""; nc=0; newloc=0; in_ac=0; next }
    /^[[:space:]]*\}[,]?[[:space:]]*$/ {
      if (inobj) printf "%s\t%s\t%d\t%d\n", id, title, nc, newloc
      inobj=0; next
    }
    inobj && in_ac {
      m=split($0, b, "\""); for (i=2;i<m;i+=2) if (b[i] != "") nc++
      if ($0 ~ /\]/) in_ac=0
      next
    }
    inobj {
      n=split($0, a, "\""); if (n < 2) next
      key=a[2]
      if (key=="id") id=a[4]
      else if (key=="title") title=a[4]
      else if (key=="acceptanceCriteria") {
        if (n >= 4) { for (i=4;i<n;i+=2) if (a[i] != "") nc++ }  # inline items
        if ($0 !~ /\]/) in_ac=1                                   # opens multi-line
      }
      else if (key=="estimatedNewLoc") { v=a[3]; gsub(/[^0-9]/, "", v); newloc=v+0 }
    }
  ' "$1" 2>/dev/null
}

# --- build_slice_pressure_hint: the ADVISORY block appended to the reviewer ---
# Emits a clearly-labelled, ADVISORY-ONLY hint block (never a verdict) listing
# every ticket's slice-pressure level + reason. Secondary file/dir signals come
# from each ticket's manifest (optional). Silent (emits nothing) on a missing /
# empty plan. Never rejects — pure text for the reviewer to weigh.
build_slice_pressure_hint() { # plan.json [manifests_dir] [budget]
  local plan="$1" mdir="${2:-}" budget="${3:-1200}"
  [ -f "$plan" ] || return 0
  budget=$((budget + 0)); [ "$budget" -gt 0 ] || budget=1200
  local rows; rows="$(slice_pressure_rows "$plan")"
  [ -n "$rows" ] || return 0

  local body="" id title nc newloc nf nd files lr lvl reason
  while IFS=$'\t' read -r id title nc newloc; do
    [ -n "$id" ] || continue
    nf=0; nd=0
    if [ -n "$mdir" ] && [ -f "$mdir/$id.md" ]; then
      files="$(manifest_relevant_files "$mdir/$id.md")"
      if [ -n "$files" ]; then
        nf="$(printf '%s\n' "$files" | grep -c '.')"
        nd="$(printf '%s\n' "$files" \
          | awk 'NF { if (index($0, "/") > 0) { sub("/[^/]*$", "", $0); print } else print "." }' \
          | sort -u | grep -c '.')"
      fi
    fi
    lr="$(slice_pressure "$nc" "$nf" "$nd" "$newloc" "$budget")"
    lvl="${lr%%$'\t'*}"; reason="${lr#*$'\t'}"
    body="$body
- $id [$lvl] $reason"
  done <<SP_ROWS_EOF
$rows
SP_ROWS_EOF
  [ -n "$body" ] || return 0

  local header="## Slice-pressure signals (heuristic — advisory only, NOT a verdict)

Computed mechanically from each ticket's OWN declared fields: acceptance-criterion
count, files and directories from its manifest, and estimatedNewLoc vs
comprehensionBudget. ADVISORY ONLY — these do NOT decide pass/fail, you do. Treat
an elevated or high signal as a prompt to look HARDER for an UNDER-SLICE: a ticket
whose title HIDES multiple behaviors, or whose scope SILENTLY OMITS part of the
surface it claims. Concrete failure mode: a \"migrate all the chrome to tokens\"
ticket that never names App.tsx or the Toolbar is an under-slice — reject it and
tell the planner the omitted surface. A low signal is NOT a licence to pass a
coupled or horizontal ticket."
  printf '%s\n%s' "$header" "$body"
}

# --- where a gate stages an in-package quarantine (S87) ----------------------
# Given a tree and a package-rel path (from ticket_target_package), echo the
# tab-separated RUN dir the runner cd's into (`<tree>/<pkg>`) and the STAGE dir the
# quarantine copies into (`<run>/__lcarsq__`). `__lcarsq__` is a NON-dot dir so
# vitest's default `**/*.test.ts` include discovers it. Used only on the non-empty
# (sub-package) branch — the empty branch keeps each gate's existing `.lcars-*` dir.
lcarsq_stage() { # tree pkg_rel  → "<run_dir>\t<stage_dir>"
  local run_dir="$1/$2"
  printf '%s\t%s' "$run_dir" "$run_dir/__lcarsq__"
}

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
    '__lcarsq__/' '__lcarsq__/*' '*/__lcarsq__' '*/__lcarsq__/*' \
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

# --- resolve a mission's RECORDED base as a git ref -------------------------
# A mission's branch must be born from its OWN recorded base (state.json `base`,
# default `main`), NEVER from whatever HEAD the shared $REPO_ROOT happens to be
# on — under two concurrent missions in one clone that ambient HEAD is the OTHER
# mission's branch, so a born-from-HEAD branch inherits the sibling's commits
# (the second contamination vector — branch CREATION, distinct from the replay
# race). Resolution order mirrors reconcile_base_ref: the remote-tracking ref
# first, then the local branch. Echoes the ref (empty ⇒ unresolvable, e.g. a
# brand-new local repo whose base is the initial unborn HEAD).
mission_base_ref() { # → echoes refs/remotes/origin/<base> | refs/heads/<base> | ""
  local base; base="$(json_str "$STATE" base)"; base="${base:-main}"
  if "$GIT_BIN" show-ref --verify --quiet "refs/remotes/origin/$base"; then
    printf 'refs/remotes/origin/%s' "$base"
  elif "$GIT_BIN" show-ref --verify --quiet "refs/heads/$base"; then
    printf 'refs/heads/%s' "$base"
  fi
}

# --- create the mission branch from its recorded base, idempotently, LOCKED --
# Guarantees `refs/heads/$branch` exists and is rooted at the mission's recorded
# base BEFORE any ticket builds. Done up front in cmd_implement so:
#   • make_ticket_worktree ALWAYS finds the branch → every ticket builds in a
#     worktree cut from the CORRECT base (never the in-tree fallback), and
#   • the in-tree `checkout -b` fallback in commit_ticket never has to CREATE
#     the branch from the ambient (possibly sibling-mission) HEAD.
# The create runs under the EXISTING repo-global replay mutex so two concurrent
# missions in one clone can't race the existence check ↔ create. Idempotent: a
# branch that already exists is left exactly as-is (no reset — a re-entered or
# resumed mission keeps its commits). Best-effort: an unresolvable base (unborn
# initial HEAD) leaves the branch uncreated and the original in-tree fallback
# still handles it. Single-mission runs take an uncontended lock (near-zero).
ensure_mission_branch() { # branch
  local branch="$1"
  [ -n "$branch" ] || return 0
  acquire_replay_lock
  if ! "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
    local ref; ref="$(mission_base_ref)"
    [ -n "$ref" ] && "$GIT_BIN" branch "$branch" "$ref" >/dev/null 2>&1 || :
  fi
  release_replay_lock
  return 0
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

  # WORKTREE MODE (Session 37 — intra-wave parallelism): when the ticket built in
  # its OWN per-ticket `git worktree` ($LCARS_TICKET_WORKTREE set), HEAD is a
  # DETACHED head at the mission-branch tip — the branch itself is checked out in
  # the main tree and git forbids a second checkout of it. So we skip the branch
  # checkout entirely and commit the scoped diff on the detached HEAD; the
  # resulting commit OBJECT is recorded to .commit-sha, and cmd_implement
  # cherry-picks it onto the real mission branch SERIALLY in plan order. The
  # scoped-staging discipline and the commit MESSAGE format below are unchanged.
  if [ -z "${LCARS_TICKET_WORKTREE:-}" ]; then
    local cur; cur="$("$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ "$cur" != "$branch" ]; then
      if "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
        "$GIT_BIN" checkout "$branch" >/dev/null 2>&1 \
          || { COMMIT_NOTE="  ⚠ could not checkout $branch — commit ticket $1 by hand."; return 0; }
      else
        # Defense-in-depth (branch-CREATION contamination): cmd_implement already
        # created the branch up front from the mission's recorded base under the
        # lock, so this path should be unreachable. If it IS reached, NEVER use
        # `checkout -b` (which would root the branch at the ambient $REPO_ROOT
        # HEAD — under concurrency a SIBLING mission's branch). Create it from the
        # resolved base ref, atomically under the SAME replay mutex, then check it
        # out. Falls back to the old behaviour only if the base is unresolvable.
        acquire_replay_lock
        if ! "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
          local _bref; _bref="$(mission_base_ref)"
          [ -n "$_bref" ] && "$GIT_BIN" branch "$branch" "$_bref" >/dev/null 2>&1 || :
        fi
        release_replay_lock
        if "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
          "$GIT_BIN" checkout "$branch" >/dev/null 2>&1 \
            || { COMMIT_NOTE="  ⚠ could not checkout $branch — commit ticket $1 by hand."; return 0; }
        else
          "$GIT_BIN" checkout -b "$branch" >/dev/null 2>&1 \
            || { COMMIT_NOTE="  ⚠ could not create $branch — commit ticket $1 by hand."; return 0; }
        fi
      fi
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
  # Worktree mode: stash the new commit OBJECT id so cmd_implement can cherry-pick
  # it onto the real mission branch in plan order. (Shared mission dir → visible
  # to the parent.) In the normal path this file is never written/read.
  if [ -n "${LCARS_TICKET_WORKTREE:-}" ]; then
    "$GIT_BIN" rev-parse HEAD >"$(ticket_dir "$1")/.commit-sha" 2>/dev/null || :
  fi
  # After the ticket commits, sweep the HARNESS-OWNED runner scratch from the
  # tree so it never lingers into later tickets or the captain's `git status`.
  # ONLY the harness's own `.lcars-run-*` files, and never a file the captain had
  # before the ticket (the .untracked-before snapshot) or worker output under
  # .git/lcars — so the captain's work is never destroyed.
  cleanup_runner_scratch "$before"
}

# --- S102: commit the LOCKED test in its OWN commit, BEFORE the Implementer ---
# Tests ride along into the PR (S102). At the END of Phase 1 (impl-save-tests), the
# Test-Writer's fail-first test has been placed in-tree at the repo convention (S101),
# self-smoked, snapshotted (tests.sha256), and passed the red gate. Here we commit
# EXACTLY those locked test file(s) as their OWN commit, so they merge to `main` and
# downstream contributors inherit the coverage — WITHOUT handing the Implementer an
# editable test:
#   • WORKTREE MODE ($LCARS_TICKET_WORKTREE): the ticket built on a DETACHED HEAD at
#     the mission-branch tip. Commit the test there and record the commit OBJECT to
#     .test-commit-sha; the parent cherry-picks it onto the real branch in plan order
#     JUST BEFORE the impl commit, so history is test-commit → impl-commit.
#   • NON-WORKTREE + a real mission branch (rare — a direct implement-ticket call):
#     mirror commit_ticket — checkout the branch, then commit.
#   • NO mission branch (branch-less / local-only): SKIP — keep S101 behaviour (tests
#     stay in-tree + mirrored, uncommitted); the caller then records them in
#     .untracked-before so commit_ticket never stages them. Back-compat.
# We stage ONLY the snapshot's test relpaths, EXPLICITLY (never `git add -u`/`-A`), so
# the greenfield stubs (STUB_RELS) and every other change stay UNCOMMITTED and
# overwritable by the Implementer. Sets COMMIT_TESTS_NOTE to the outcome; never crashes
# (a defensive skip leaves the tests uncommitted, exactly as S101 left them).
COMMIT_TESTS_NOTE=""
commit_locked_tests() { # ticket
  COMMIT_TESTS_NOTE=""
  local t="$1"
  local branch; branch="$(json_str "$STATE" branch)"
  # Branch-less / local-only mission → S102 skip (S101 behaviour preserved).
  if [ -z "$branch" ]; then COMMIT_TESTS_NOTE="skip-no-branch"; return 0; fi

  # The locked test relpaths — EXACTLY what impl-save-tests just placed + snapshotted.
  local rels; rels="$(snapshot_test_rels "$t")"
  [ -n "$(printf '%s' "$rels" | grep . || true)" ] || { COMMIT_TESTS_NOTE="skip-no-tests"; return 0; }

  # Deterministic, legible subject: <behavior> = the ticket's plan title when cheaply
  # available (approved-plan.json), else a stable generic phrase (kept stable so the
  # commit subject is reproducible under test).
  local title=""
  [ -f "$MISSION_DIR/approved-plan.json" ] && title="$(ticket_title "$MISSION_DIR/approved-plan.json" "$t" 2>/dev/null || true)"
  [ -n "$title" ] || title="locked failing test"
  local msg="test($t): $title (LCARS Test-Writer)"

  # NON-WORKTREE + real branch: get onto the branch first (mirror commit_ticket).
  if [ -z "${LCARS_TICKET_WORKTREE:-}" ]; then
    local cur; cur="$( cd "$REPO_ROOT" && "$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null )"
    if [ "$cur" != "$branch" ]; then
      if "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
        ( cd "$REPO_ROOT" && "$GIT_BIN" checkout "$branch" >/dev/null 2>&1 ) \
          || { COMMIT_TESTS_NOTE="skip-checkout-failed"; return 0; }
      else
        COMMIT_TESTS_NOTE="skip-no-branch-ref"; return 0
      fi
    fi
  fi

  ensure_scratch_excluded

  # Stage ONLY the locked test file(s), explicitly. NEVER `git add -u`/`-A` here.
  local rel staged=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    ( cd "$REPO_ROOT" && "$GIT_BIN" add -- "$rel" >/dev/null 2>&1 ) && staged=1
  done <<REL_EOF
$rels
REL_EOF
  # Defensive: nothing actually staged → keep the tests uncommitted (S101 behaviour).
  if [ "$staged" != 1 ] || ( cd "$REPO_ROOT" && "$GIT_BIN" diff --cached --quiet 2>/dev/null ); then
    COMMIT_TESTS_NOTE="skip-nothing-staged"; return 0
  fi
  ( cd "$REPO_ROOT" && "$GIT_BIN" commit -q -m "$msg" >/dev/null 2>&1 ) \
    || { COMMIT_TESTS_NOTE="skip-commit-failed"; return 0; }
  # Worktree mode: stash the test commit OBJECT so the parent cherry-picks it BEFORE
  # the impl commit. (Shared mission dir → visible to the parent.)
  if [ -n "${LCARS_TICKET_WORKTREE:-}" ]; then
    ( cd "$REPO_ROOT" && "$GIT_BIN" rev-parse HEAD ) >"$(ticket_dir "$t")/.test-commit-sha" 2>/dev/null || :
  fi
  COMMIT_TESTS_NOTE="committed"
  return 0
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

# --- S96: table-driven classifier signatures -------------------------------
# The red-gate failure detectors below (compile / resolution / env) share ONE
# data table keyed by CATEGORY, so a future stack (multi-stack-dev.md) slots a new
# recognizer in HERE instead of editing each detector inline. This session adds NO
# new language arms: the `resolution`, `compile`, and `env` patterns are
# BYTE-IDENTICAL to the pre-S96 inline regexes (regression — JS/Python classify
# exactly as before); only their STORAGE moved into this one lookup. `assertion`
# is a NEW, classify-ONLY signature (used solely by classify_impl_failure to tell
# a genuine assertion red from a no-coherent-red rejection); it is NOT consulted by
# the three red-gate detectors, so it cannot change any existing gate verdict.
rg_signature() { # category → the ERE for that category's runner-output signature
  case "$1" in
    resolution)
      printf '%s' 'Cannot find module|ERR_MODULE_NOT_FOUND|ERR_REQUIRE_ESM|ERR_UNSUPPORTED_DIR_IMPORT|Failed to load url|Failed to resolve import|Failed to resolve entry|Does the file exist\?|Rollup failed to resolve' ;;
    compile)
      printf '%s' 'SyntaxError|Unexpected (token|identifier|end of input|string)|Cannot find module|ERR_MODULE_NOT_FOUND|ERR_REQUIRE_ESM|ERR_UNKNOWN_FILE_EXTENSION|is not defined|ParseError|Parse error|cannot parse|invalid syntax|IndentationError|unexpected EOF|compilation (failed|error)' ;;
    env)
      printf '%s' '^(/[^: ]*/)?(sh|bash|zsh|dash|ash|ksh|env)(\[[0-9]+\])?:.*not found|^(vitest|jest|mocha|pytest|ts-node|tsx|deno|bun|npm|npx|pnpm|yarn|node):.*not found|ERR_PNPM_|node_modules.*(missing|not found|No such)|Cannot find module.*node_modules|WARN.*node_modules|ModuleNotFoundError|No module named|: Permission denied$|: cannot execute|cannot execute binary file|^env: .+: No such file or directory|No such file or directory.*(venv|virtualenv|/bin/activate|/bin/python)|source[[:space:]].*/activate' ;;
    assertion)
      # A GENUINE assertion red (the runner started, tests ran, an assertion FAILED)
      # — common vitest/jest/node/pytest phrasings. Classify-only: it never runs
      # against the gate, so it can never accept a red the gate would reject.
      printf '%s' 'AssertionError|assert(ion)?[[:space:]_-]*(error|failed)|expected .+ (to|toBe|toEqual|to be|to equal|to have|to contain|to match)|[0-9]+ (failed|failing)|Tests?:.*(failed|fail)|✗|✕|●[[:space:]]|^[[:space:]]*FAIL[[:space:]]' ;;
    zerotests)
      # S99 — the runner FINISHED but collected/ran ZERO tests. CLASSIFY-ONLY (the
      # self-smoke's zero-tests verdict + classify_impl_failure); NEVER consulted by
      # red_gate_ok's verdicts. TIGHT on purpose: it must NOT match a healthy red
      # suite that happens to print "0 passed" — only the runner's own "no tests
      # collected / ran" phrasings.
      printf '%s' 'No test files found|No test suite found in|No tests found|no tests ran|Ran 0 tests|collected 0 items' ;;
    hang)
      # S99 — a Test-Writer suite that HUNG under the pre-gate self-smoke timeout.
      # CLASSIFY-ONLY (classify_impl_failure at exhaustion); NEVER consulted by
      # red_gate_ok. Anchored to the self-smoke's OWN captured marker so it cannot
      # false-positive on ordinary runner chatter.
      printf '%s' 'SELF-SMOKE — your suite HUNG|the suite never (settled|finished) within the hard timeout' ;;
  esac
}

# --- BUG-022: distinguish a compile/load failure from a valid assertion red --
# The red gate wants the quarantined suite RED before the Implementer runs, but a
# Test-Writer that emits a NON-COMPILING test (a SyntaxError, an import/parse error,
# a load-time ReferenceError, or a leftover placeholder token like `<REPLACE>`)
# also exits non-zero — and the gate would (wrongly) accept that as "valid red" and
# hand a NON-RUNNABLE contract to the Implementer. The Implementer cannot edit the
# immutable test to fix a syntax error, so it flags the ticket after one attempt.
# We therefore triage the runner OUTPUT: a CLEAR compile/load failure is REJECTED
# back to the Test-Writer (re-author, with the runner's error as feedback) via the
# SAME RED_GATE_SIGNAL loop a trivially-green suite uses; a normal assertion failure
# still passes the red gate untouched. Conservative by design — only signatures that
# unambiguously mean "the file did not even load" divert; anything else is a real red.
#
# Signatures (node runner + an engine placeholder leak):
#   • SyntaxError / parse error                     (SyntaxError, Unexpected token/identifier/end of input)
#   • module load failure                           (Cannot find module, ERR_MODULE_NOT_FOUND, ERR_REQUIRE_ESM)
#   • a bundler MODULE-RESOLUTION failure            (vite/vitest/rollup: Failed to load url / Failed to
#                                                     resolve import|entry / "Does the file exist?" — see
#                                                     red_gate_resolution_failure for the full subset & rationale)
#   • a load-time ReferenceError                    (… is not defined  — a symbol unresolved before any test ran)
#   • an unsubstituted Test-Writer placeholder      (<REPLACE>, <TODO>, <PLACEHOLDER>, etc.)
# Returns 0 (compile/load failure detected) or 1 (none).
red_gate_compile_failure() { # runner-output → 0 if a compile/load failure signature is present
  local out="$1"
  # An unsubstituted placeholder token the Test-Writer left behind is a guaranteed
  # parse failure (e.g. copilot's `const track<REPLACE> = …`). Catch it directly.
  case "$out" in
    *'<REPLACE>'*|*'<PLACEHOLDER>'*|*'<TODO>'*|*'<FILL'*|*'<INSERT'*) return 0 ;;
  esac
  # A bundler/ESM MODULE-RESOLUTION failure (vite/vitest/rollup) is a load failure too
  # — the test could not even resolve its import of the code under test, so nothing ran.
  # Delegated to red_gate_resolution_failure (shared with red_gate_ok's actionable reason).
  red_gate_resolution_failure "$out" && return 0
  # node/JS compile + load signatures, plus a generic interpreter parse error. These
  # are emitted to stderr (which the gate captures with 2>&1) BEFORE any test runs.
  # Pattern is the `compile` arm of rg_signature (byte-identical to the prior inline).
  printf '%s' "$out" | grep -Eq "$(rg_signature compile)" \
    && return 0
  return 1
}

# BUG-024 (gate-worktree-deps): the module-RESOLUTION subset of red_gate_compile_failure.
# The quarantined test LOADED into a WORKING runner but could not RESOLVE its import of
# the code under test. This is DISTINCT from a pure SyntaxError because the FIX differs:
# the harness runs the quarantined test from the ticket's package quarantine dir
# `<pkg>/__lcarsq__/`, so a CO-LOCATED `./<sibling>` import (authored as if the test sat
# next to the source) cannot resolve from there — vitest/vite/rollup then report the
# failure with their OWN phrasing, which node's bare `Cannot find module` did not cover.
# red_gate_ok uses a match here to give a RESOLUTION-specific, actionable reason (import
# package-root-relative or by package name, NOT co-located) so the retry self-corrects.
# Each signature is a RUNNER module-resolution failure — NOT a normal assertion failure,
# and NOT a test that imports an EXISTING module but a not-yet-defined SYMBOL (that loads
# fine → undefined symbol → a VALID assertion fail-first that must still be accepted):
#   • Cannot find module / ERR_MODULE_NOT_FOUND / ERR_REQUIRE_ESM — node's own resolver.
#   • ERR_UNSUPPORTED_DIR_IMPORT                     — node refused a directory import (no resolution).
#   • Failed to load url                             — vite/vitest could not load the imported url.
#   • Failed to resolve import / Failed to resolve entry — vite/vitest could not resolve the specifier.
#   • Does the file exist\?                          — the tail vitest appends to a Failed-to-load-url error.
#   • Rollup failed to resolve                       — rollup/vite build-time resolution failure.
# Returns 0 (a module-resolution/load failure) or 1 (none).
red_gate_resolution_failure() { # runner-output → 0 if a module-resolution failure signature is present
  local out="$1"
  # Pattern is the `resolution` arm of rg_signature (byte-identical to the prior inline).
  printf '%s' "$out" | grep -Eq "$(rg_signature resolution)" \
    && return 0
  return 1
}

# S95 (greenfield-tests): pull the EXACT unresolved import specifier(s) out of a
# resolution-failure runner output so red_gate_ok's feedback can NAME them up
# front instead of burying them in vite's verbose stack trace. A strong model
# (claude) digs the specifier out of the raw tail; a weaker one (copilot) does
# NOT reliably self-correct within the 3-attempt cap — so a legitimately-
# greenfield ticket that creates MULTIPLE new modules dies "no usable tests".
# Naming each specifier turns a fuzzy retry into a precise, actionable one.
#
# PURE string parsing — reads runner output from $1 or stdin, echoes the DISTINCT
# specifier(s) it can extract (one per line, deduped), empty output if none.
# Defensive: an unrecognised format echoes nothing and never errors. Portable
# BSD/GNU only (grep -oE + sed; no PCRE \K, no grep -P). Covers the common
# bundler/runtime phrasings:
#   • Failed to resolve import "X" / 'X'        (vite/vitest — quoted specifier)
#   • Failed to resolve entry for package "X"   (vite — quoted package name)
#   • Cannot find module 'X' / "X"              (node resolver — quoted specifier)
#   • Cannot find package 'X' / "X"             (node/pnpm — quoted package)
#   • Failed to load url X                       (vite — bare url up to whitespace)
unresolved_imports_in_output() { # runner-output ($1 or stdin) → distinct unresolved specifier(s), one per line
  local out
  if [ "$#" -gt 0 ]; then out="$1"; else out="$(cat)"; fi
  {
    # Quoted specifiers: extract the token inside the FIRST quote pair on each match.
    printf '%s\n' "$out" | grep -oE \
      '(Failed to resolve import|Failed to resolve entry for package|Cannot find module|Cannot find package)[[:space:]]+["'"'"'][^"'"'"']+["'"'"']' \
      | sed -E 's/.*["'"'"']([^"'"'"']+)["'"'"'].*/\1/'
    # Bare (unquoted) url form: everything up to the next whitespace or paren.
    printf '%s\n' "$out" | grep -oE 'Failed to load url[[:space:]]+[^[:space:])]+' \
      | sed -E 's/^Failed to load url[[:space:]]+//'
  } | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u
}

# S83 (gate-worktree-deps): an un-runnable ENVIRONMENT detector — companion to
# red_gate_compile_failure. That detector catches a test file that LOADED into a
# WORKING runner but failed to PARSE/COMPILE. This one catches the DIFFERENT
# failure where the test RUNNER ITSELF could not START at all: the gate worktree
# is not provisioned — no node_modules / venv, the runner binary is absent, no
# pnpm lockfile, or a permissions error. Such a run exits non-zero with output
# that DIFFERS from the empty-dir probe (so `ignored_var=no`), and WITHOUT this
# guard the red gate would WRONGLY accept it as a satisfying fail-first red even
# though not a single assertion ever executed — the bug then stays silent until
# it is fatal at a downstream green gate. We CLASSIFY these startup failures so
# red_gate_ok can REFUSE to count them and fail LOUD with an actionable reason.
# This is an ADDITIONAL guard that REJECTS MORE reds — it never loosens the gate.
# (Provisioning itself is S81/S82; this session only classifies output.)
#
# Each signature below is a runner-STARTUP failure (emitted before any test ran).
# CRITICAL: every shell/exec-diagnostic arm is ANCHORED to the way the shell ITSELF
# prints the error, so an assertion that merely PRINTS the same phrase — typically
# QUOTED inside an expected/received diff (`expected 'ok' to equal 'command not
# found'`), mid-line, or inside a test NAME (`it('shows git: command not found')`) —
# does NOT match. We MUST NOT block a genuine fail-first (that would re-break Implement).
#   • shell "command not found" / "<x>: not found": ONLY when the line BEGINS with the
#       interpreter's own diagnostic prefix (sh:/bash:/zsh:/dash:/ash:/ksh:/env:, opt.
#       leading path / `[pid]`) — e.g. `sh: vitest: command not found`, `bash: line 1:
#       vitestxyz: command not found`, `zsh: command not found: vitest`, `sh: jest: not
#       found`. An assertion line starts with `AssertionError:` / `it(` / `{` instead.
#   • runner-binary self-report: a line BEGINNING with a known runner name then
#       `: … not found` (vitest|jest|mocha|pytest|ts-node|tsx|deno|bun|npm|npx|pnpm|
#       yarn|node) — the only bare `<name>: not found` forms the brief ever named.
#   • ERR_PNPM_… — pnpm refused to run (e.g. ERR_PNPM_NO_LOCKFILE) → deps not installed.
#   • node_modules … missing/not found/No such — JS deps not installed in the worktree.
#   • ModuleNotFoundError / No module named — the Python interpreter could not import
#       the runner/its deps (venv not provisioned).
#   • exec-permission/format errors as the SHELL prints them at end-of-line: a path
#       then `: Permission denied$`, or `: cannot execute` / `cannot execute binary
#       file`. The assertion forms end with a QUOTE (`…'Permission denied'`) or quote
#       the phrase (`'cannot execute migration'`), so neither the end-anchored nor the
#       colon-prefixed arm matches them.
#   • `env: <interp>: No such file or directory` — a missing interpreter via shebang
#       (e.g. `env: node: No such file or directory`), anchored at line start.
#   • venv-missing: `No such file or directory` pointing at a venv/bin path, or a
#       missing `source …/activate` step.
# So "2 failed", "expected 3 to be 4", and every quoted/test-name phrase above do NOT
# match — kept TIGHT, no false positive that would block a genuine fail-first.
# Returns 0 (the runner could not execute) or 1 (no env-failure signature).
red_gate_env_failure() { # runner-output → 0 if the runner could not execute
  local out="$1"
  # Pattern is the `env` arm of rg_signature (byte-identical to the prior inline).
  printf '%s' "$out" | grep -Eq "$(rg_signature env)" \
    && return 0
  return 1
}

# --- S96: actionable failure classification --------------------------------
# When an Implement (or retest) attempt STOPS, name ONE root-cause CATEGORY so the
# failure event + awaiting-human gate say WHY, instead of the generic "no usable
# tests". PURE + SIGNAL-ONLY: reads only CAPTURED output, runs nothing, and NEVER
# changes a verdict — it labels a failure the gate already decided. The three
# inputs are the last attempt's RUNNER output (the red-gate signal / runner
# stderr), the WORKER's own stdout+stderr, and the newline-separated list of FILES
# the worker wrote (its test file(s) + any S94 stub(s)).
#
# PRECEDENCE (first match wins) — mirrors red_gate_ok's own triage order where it
# matters, so the category always AGREES with the verdict already rendered:
#   1. empty-worker-output — the worker produced NOTHING (no file AND empty
#      stdout/stderr). Checked FIRST: there is no runner output to classify, and
#      this is the S98 worker-health signal (a dead/transient CLI, not a code bug).
#   2. test-writer-hang    — the S99 pre-gate self-smoke's HANG marker (the suite
#      never settled under the hard timeout — a never-settling awaited/thenable mock
#      or an infinite async init). Checked BEFORE env so a hang is never mis-read as
#      an unprovisioned runner.
#   3. env-failure         — the runner could not LAUNCH (red_gate_env_failure).
#      Checked BEFORE resolution/compile, exactly as red_gate_ok triages env first,
#      so an unprovisioned runner never mis-reads as a code fault.
#   4. missing-new-module / bad-import-path — a module-RESOLUTION failure
#      (red_gate_resolution_failure). Greenfield (a path the ticket CREATES — the
#      worker wrote a stub/file mirroring the unresolved specifier, per S94) →
#      missing-new-module; otherwise (a typo'd / non-created path) → bad-import-path.
#   5. genuine-red-exhausted — the runner output shows a REAL assertion red
#      (rg_signature assertion) with none of the above causes: the tests genuinely
#      went red and attempts ran out.
#   6. over-broad-slice    — a test file WAS written but nothing above pinned a
#      coherent failing test (green-on-nothing / ignored-var / a non-resolution load
#      defect): the Test-Writer wrote something the gate kept rejecting.
#   7. over-broad-slice    — fallback: no file was written, but NOT truly empty —
#      some signal is present (runner output and/or worker noise), the truly-nothing
#      case having been claimed by #1. A worker that emitted output/runner signal but
#      no usable test file is a bad/over-broad attempt, NOT an empty/transient-CLI miss.
classify_impl_failure() { # runner_out  worker_out  files_written
  local runner_out="${1:-}" worker_out="${2:-}" files_written="${3:-}"
  local has_files=no has_runner=no has_worker=no
  [ -n "$(printf '%s' "$files_written" | tr -d '[:space:]')" ] && has_files=yes
  [ -n "$(printf '%s' "$runner_out"    | tr -d '[:space:]')" ] && has_runner=yes
  [ -n "$(printf '%s' "$worker_out"    | tr -d '[:space:]')" ] && has_worker=yes

  # 1. empty-worker-output — nothing produced at all.
  if [ "$has_files" = no ] && [ "$has_runner" = no ] && [ "$has_worker" = no ]; then
    printf 'empty-worker-output'; return 0
  fi

  # 2. test-writer-hang — a Test-Writer self-smoke HANG (the suite never settled
  # under the hard timeout — a never-settling awaited/thenable mock or an infinite
  # async init). Recognised from the self-smoke's own captured marker so an
  # EXHAUSTED ticket names the hang instead of a generic over-broad slice. Checked
  # before env so a hang is never mis-read as an unprovisioned runner.
  if printf '%s' "$runner_out" | grep -Eq "$(rg_signature hang)"; then
    printf 'test-writer-hang'; return 0
  fi

  # 3. env-failure — the runner could not start (checked before resolution/compile).
  if red_gate_env_failure "$runner_out"; then
    printf 'env-failure'; return 0
  fi

  # 4. module-resolution — greenfield (a created module) vs a typo/non-created path.
  if red_gate_resolution_failure "$runner_out"; then
    if unresolved_specifier_is_created "$runner_out" "$files_written"; then
      printf 'missing-new-module'
    else
      printf 'bad-import-path'
    fi
    return 0
  fi

  # 5. genuine-red-exhausted — a real assertion red exhausted the attempt cap.
  if printf '%s' "$runner_out" | grep -Eq "$(rg_signature assertion)"; then
    printf 'genuine-red-exhausted'; return 0
  fi

  # 6. over-broad-slice — a file was written but no coherent red ever converged.
  if [ "$has_files" = yes ]; then
    printf 'over-broad-slice'; return 0
  fi

  # 7. over-broad-slice — no file written, but NOT truly empty: some signal is
  #    present (runner output and/or worker noise), since the truly-nothing case is
  #    caught by category #1 above. A worker that produced output/runner signal but
  #    no usable test file is a bad/over-broad attempt (the Test-Writer could not pin
  #    a red), NOT an empty/transient-CLI miss — so it must NOT read as empty-worker-output.
  printf 'over-broad-slice'
}

# S96 helper: decide whether ANY unresolved import specifier in a resolution
# failure names a module the TICKET is trying to CREATE (greenfield) — i.e. the
# worker WROTE a file (an S94 stub, or the source) mirroring that specifier's
# module name. If so the resolution failure is `missing-new-module` (the stub just
# did not resolve yet); if the specifier matches nothing the worker wrote, it is a
# `bad-import-path` (a typo'd / non-created path). A *.test / *.spec file is the
# TEST, not a created module, so it never counts as the greenfield target. PURE
# string comparison; returns 0 if greenfield, 1 otherwise.
unresolved_specifier_is_created() { # runner_out  files_written  → 0 if greenfield
  local runner_out="$1" files_written="$2" spec base f fb
  [ -n "$(printf '%s' "$files_written" | tr -d '[:space:]')" ] || return 1
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    base="${spec##*/}"; base="${base%.*}"     # module stem: drop dir prefix + ext
    [ -n "$base" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      fb="${f##*/}"; fb="${fb%.*}"            # written-file stem
      case "$fb" in *.test|*.spec) continue ;; esac
      [ "$fb" = "$base" ] && return 0
    done <<EOF
$files_written
EOF
  done <<EOF
$(unresolved_imports_in_output "$runner_out")
EOF
  return 1
}

# S96: the human-facing phrase for a failure category — used in the failure event
# detail, the awaiting-human gate / stop text, and the notification, so the board
# reads e.g. "over-broad slice (no coherent failing test)" instead of a bare token.
impl_failure_category_phrase() { # category → phrase
  case "$1" in
    missing-new-module)         printf 'missing new module (a greenfield import the ticket must create did not resolve)' ;;
    bad-import-path)            printf 'bad import path (a mistyped / non-created import did not resolve)' ;;
    over-broad-slice)           printf 'over-broad slice (no coherent failing test — the Test-Writer could not pin a red)' ;;
    empty-worker-output)        printf 'empty worker output (the worker produced no file and no output — likely a transient CLI failure, not a code problem)' ;;
    test-writer-hang)           printf 'test-writer hang (the suite never settled under the pre-gate self-smoke timeout — likely an awaited / thenable mock; caught before the Implementer)' ;;
    env-failure|runner-startup) printf 'environment failure (the test runner could not start — the worktree is not provisioned; NOT a code problem)' ;;
    genuine-red-exhausted)      printf 'genuine red exhausted (the tests went red but never turned green within the attempt cap)' ;;
    *)                          printf '%s' "$1" ;;
  esac
}

# S98: decide whether a just-finished cold worker produced NOTHING AT ALL — the
# transient-CLI signal (a dead/hung/denied worker, seen with copilot), as opposed
# to one that produced BAD work (reasoned toward a rejected suite, or wrote a file
# the gate declined). This is the per-attempt, phase-level companion to
# classify_impl_failure's `empty-worker-output` category, run INLINE in the
# Test-Writer and Implementer loops BEFORE the "did it write the expected file"
# check, so an empty worker is bounded-retried and escalated distinctly.
#
# It reads ONLY the worker's OUTDIR contents — the NON-hidden files it wrote plus
# the hidden .worker.out / .worker.err captures — and NEVER the CLI name, so the
# detection is inherently engine-agnostic (no vendor special-casing). Returns:
#   • 0 (nothing) — the worker wrote NO real file AND its stdout+stderr, stripped
#                   of whitespace, are empty.
#   • 1 (something) — a real file exists, OR the captures held any output at all
#                   (a worker that did something — even a bad something).
worker_produced_nothing() { # outdir → 0 if the worker produced nothing at all
  local outdir="$1"
  [ -d "$outdir" ] || return 0   # no outdir at all ⇒ nothing was produced
  # Any REAL artifact (anything the worker wrote EXCEPT the hidden capture files)
  # means it produced something — regardless of stdout/stderr.
  if [ -n "$(find "$outdir" -type f \
              ! -name '.worker.out' ! -name '.worker.err' -print -quit 2>/dev/null)" ]; then
    return 1
  fi
  # No real file: fall back to the captures. Any non-whitespace output means the
  # worker DID run and say something (a real, classifiable attempt) — NOT empty.
  if [ -n "$(cat "$outdir/.worker.out" "$outdir/.worker.err" 2>/dev/null | tr -d '[:space:]')" ]; then
    return 1
  fi
  return 0   # no file AND no output ⇒ produced nothing
}

# --- GUARDRAIL 1: the red gate ----------------------------------------------
# BUG-007 contract. Run the configured test command against ONLY the just-written
# QUARANTINED tests, with NO implementation present, and decide on the quarantined
# tests ALONE — never on the repo's existing suite. The verdict is a PURE function
# of "did the quarantined tests fail":
#
#   • quarantined suite RED (cmd exits non-zero)        → return 0  (SAFE — hand off)
#   • quarantined suite GREEN, and we can PROVE it was   → return 1  (green-on-nothing — REJECT)
#     the quarantined tests that passed
#   • quarantined suite GREEN, but the command IGNORES   → return 1  (CAN'T PROVE — BLOCK loud,
#     $LCARS_TESTS_DIR (so we cannot tell whether it       NEVER a green-light)
#     ran the quarantined tests or the repo's own suite)
#   • no runner configured                               → return 2  (CANNOT APPLY — block loud)
#
# The command runs from the repo root with $LCARS_TESTS_DIR pointing at the
# quarantined tests, so a real per-repo runner honours that var to scope itself.
# We then PROBE with $LCARS_TESTS_DIR pointing at an EMPTY dir: if the exit code
# is identical, the command did not react to the var (it ran a fixed target — the
# repo's own suite), so a green result proves NOTHING about the quarantined tests.
# We NEVER discard the rc or the output — both are surfaced to $RED_GATE_SIGNAL
# (if set) so the human and the next grounded Test-Writer attempt see WHY.
RED_GATE_SIGNAL=""   # caller may point this at a file to capture the rejection signal
# S101: the repo's test convention (co-located | __tests__ | tests) the harness
# placed this test at, so the resolution-failure hint tells the Test-Writer to
# re-author the import + stub for the ACTUAL in-tree location. Default co-located
# (groutwork's + the harness default). SIGNAL/WORDING ONLY — never a verdict.
RED_GATE_CONVENTION="co-located"
red_gate_ok() { # quarantined-tests-dir [run-dir]
  # S87: run-dir is the cwd the runner is invoked from (BOTH the real run AND the
  # empty-dir probe), default $REPO_ROOT (byte-identical to before). A monorepo
  # ticket passes its own package dir so vitest/jest discover & filter at the
  # package root. The probe still cd's the SAME place and consumes $LCARS_TESTS_DIR,
  # so its differ-requirement is preserved.
  local tdir="$1" run_dir="${2:-$REPO_ROOT}" cmd rc=0 prc=0 out probe_out reason=""
  cmd="$(resolve_test_cmd)"
  if [ -z "$cmd" ]; then
    # NO RUNNER configured: the gate cannot run anything. This is the documented,
    # pre-existing degradation for repos without a test command — it is NOT a fix
    # to widen and it green-lights nothing on its own (there is literally no suite
    # to pass). We surface it LOUDLY (it is a real hole, not a silent pass) and
    # leave it unchanged: WIDENING it would be the regression BUG-007 forbids.
    printf '  ⚠ RED GATE SKIPPED — no test command (set `testCommand` in .git/lcars/config.json or $LCARS_TEST_CMD). The harness cannot prove the suite fails-first without a runner; configure one to close this gap.\n' >&2
    return 0
  fi

  out="$(cd "$run_dir" && LCARS_TESTS_DIR="$tdir" bash -c "$cmd" 2>&1)" || rc=$?

  # PROBE: re-run the SAME command with an EMPTY quarantine dir. This is the only
  # way to prove the command reacts to $LCARS_TESTS_DIR (i.e. it scoped itself to
  # the quarantined tests) versus running a fixed target (the repo's own suite).
  # We use it on BOTH verdicts:
  #   • GREEN branch — to tell a green-on-nothing from a dir-ignoring green.
  #   • RED branch  — to tell a genuine red of the quarantined tests from a
  #     dir-ignoring red on the repo's own (already failing) suite.
  # A command "did NOT react" only when emptying the dir changed NOTHING — i.e.
  # the empty-dir run is IDENTICAL: same rc AND byte-identical output. Any
  # difference (different output OR different rc) ⟹ the command reacted ⟹ the
  # verdict is about the quarantined tests. rc-equality alone is INSUFFICIENT: a
  # honouring runner can exit the same non-zero rc on an empty dir as on a real
  # failing test, with DIFFERENT output — so we MUST compare output too, and err
  # toward ACCEPT on any difference (a false-BLOCK would re-introduce BUG-007).
  local empty; empty="$(mktemp -d)"
  probe_out="$(cd "$run_dir" && LCARS_TESTS_DIR="$empty" bash -c "$cmd" 2>&1)" || prc=$?
  rm -rf "$empty"
  local ignored_var=no
  if [ "$prc" -eq "$rc" ] && [ "$probe_out" = "$out" ]; then ignored_var=yes; fi

  if [ "$rc" -ne 0 ]; then
    # RED: the quarantined tests appear to fail as required. But a non-zero exit is
    # only "red = safe" when it is ABOUT the quarantined tests. If emptying the dir
    # changed NOTHING (identical rc AND output), the command IGNORED $LCARS_TESTS_DIR
    # — it ran a fixed target (e.g. the repo's own red suite), so this non-zero exit
    # proves NOTHING about the quarantined tests. BLOCK loud — never accept an
    # UNPROVEN suite. Otherwise the command reacted → genuine red → accept (as before).
    if [ "$ignored_var" = yes ]; then
      reason="RED GATE — the configured test command exited non-zero (red) but exits IDENTICALLY (same rc AND output) with NO quarantined tests present, so it IGNORES \$LCARS_TESTS_DIR and ran a FIXED target (the repo's own suite), not the quarantined tests. A red on the repo's own already-failing suite proves NOTHING about the new tests, so the harness refuses to hand them on. Command run: $cmd. Make \`testCommand\` honour \$LCARS_TESTS_DIR (run only that dir) — see \`lcars init\`."
      printf '  ✗ %s\n' "$reason" >&2
      if [ -n "$RED_GATE_SIGNAL" ]; then
        {
          printf 'rc=%s (the quarantined-tests run exited non-zero, but the command IGNORES $LCARS_TESTS_DIR so the red is unproven)\n' "$rc"
          printf '%s\n' "$reason"
        } >"$RED_GATE_SIGNAL"
      fi
      return 1
    fi
    # S83: the command reacted to the var, but a non-zero exit is only a VALID red
    # when the runner actually STARTED and a test ASSERTION failed. Triage the
    # un-runnable ENVIRONMENT first — BEFORE the compile/load check — because a
    # runner that never launched must be diagnosed as "environment not provisioned",
    # not mis-reported as a compile/load error. (The env signatures are tight enough
    # that a genuine compile error — SyntaxError, generic Cannot-find-module — does
    # NOT match here and falls through to red_gate_compile_failure below.) If the
    # output shows the runner could not start (missing node_modules/venv, an absent
    # test binary, no pnpm lockfile, a permissions error), then NOT ONE assertion ran,
    # so this red proves NOTHING about the new tests. It differs from the empty-dir
    # probe (ignored_var=no), so without this guard it would be WRONGLY accepted as a
    # satisfying fail-first. REFUSE it: route to the SAME awaiting-human / retry path a
    # genuine red-gate rejection uses, with a distinct, actionable reason. This is an
    # ADDITIONAL guard that rejects MORE reds — it does NOT loosen the gate, and leaves
    # the empty-dir probe / ignored_var / differ logic untouched. (Provisioning the
    # worktree is S81/S82; here we only classify and fail loud.)
    if red_gate_env_failure "$out"; then
      reason="RED GATE — environment not provisioned — the test runner could not start (is worktreeSetupCommand set?). The quarantined suite exited non-zero, but the failure is the RUNNER ITSELF failing to LAUNCH (missing node_modules/venv, an absent test binary, no pnpm lockfile, or a permissions error), NOT a test assertion — so not a single test ran and this red proves NOTHING about the new tests. Provision the gate worktree (set \`worktreeSetupCommand\` so the runner's dependencies are installed before the gate runs), then the suite can fail-first on its assertions. Command run: $cmd. Runner output (quarantined run):
$(printf '%s' "$out" | tail -20)"
      printf '  ✗ %s\n' "$reason" >&2
      if [ -n "$RED_GATE_SIGNAL" ]; then
        {
          printf 'rc=%s (the quarantined-tests run could not START the runner — environment not provisioned, NOT a valid assertion red)\n' "$rc"
          printf '%s\n' "$reason"
        } >"$RED_GATE_SIGNAL"
      fi
      return 1
    fi
    # BUG-022: the command reacted to the var, but a non-zero exit is only a VALID
    # red when the suite failed on ASSERTIONS. If the runner output carries a clear
    # COMPILE/LOAD failure (SyntaxError, import/parse error, a load-time unresolved
    # symbol, or an unsubstituted placeholder token), the test file did not even run
    # — handing it to the Implementer is a dead end (it cannot edit the immutable
    # test to fix the syntax). REJECT it back to the Test-Writer with the runner's
    # error as feedback, the SAME loop a trivially-green suite uses. Conservative:
    # only a clear compile/load signature diverts; a normal assertion failure falls
    # through to the accept below, exactly as before.
    if red_gate_compile_failure "$out"; then
      # BUG-024: a module-RESOLUTION load failure needs a DIFFERENT, actionable reason
      # than a pure SyntaxError. The quarantined test is executed from the ticket's
      # package quarantine dir `<package>/__lcarsq__/`, so a co-located `./<sibling>`
      # import of the code under test (authored as if the test sat next to the source)
      # cannot resolve from there. Tell the Test-Writer to import via a path that
      # resolves FROM the quarantine dir — package-root-relative or by package name —
      # so the retry self-corrects. A non-resolution compile/parse error keeps the
      # original SyntaxError wording.
      if red_gate_resolution_failure "$out"; then
        # S95 (greenfield-tests): NAME the exact unresolved specifier(s) up front
        # so a weaker worker self-corrects instead of digging them out of the raw
        # tail. Only when the parser extracts something (else byte-identical to
        # the pre-S95 reason — no empty line, no dangling label).
        # S101: the hint is CONVENTION-AWARE — the harness now places the test IN THE
        # REPO at $RED_GATE_CONVENTION and runs it IN PLACE, so the correct import +
        # stub path depends on where the test physically sits. co-located is the
        # default (groutwork); __tests__/ and top-level tests/ get their own prefix.
        local unres="" hint="" imp_form stub_form
        case "$RED_GATE_CONVENTION" in
          __tests__)  imp_form="a sibling import ONE level up, \`../<sibling>\` (the source sits in the dir ABOVE your \`__tests__/\` test)"
                      stub_form="\`stubs/<sibling>.ts\` (the harness places it beside the source, one level up from your test)" ;;
          tests)      imp_form="the source's package-root-relative path, e.g. \`../src/<dir>/<file>\` (your test lives in a top-level \`tests/\` dir)"
                      stub_form="\`stubs/<package-root>/src/<dir>/<file>.ts\` (the mirrored repo path)" ;;
          *)          imp_form="a CO-LOCATED \`./<sibling>\` import, e.g. \`import { area } from './utils'\` (your test sits NEXT TO the source)"
                      stub_form="\`stubs/<sibling>.ts\` (the harness places it beside your test)" ;;
        esac
        unres="$(unresolved_imports_in_output "$out" | paste -sd' ' - 2>/dev/null)"
        if [ -n "$unres" ]; then
          hint="SPECIFICALLY, these import(s) did not resolve: $unres. For EACH one that is a brand-new module your ticket must create, emit an EMPTY stub for it under stubs/ named for the sibling — $stub_form — so it resolves; if instead the import PATH is wrong, re-author it as $imp_form. Create a stub for EVERY brand-new module you import — a single missing stub fails the whole suite to load. "
        fi
        reason="RED GATE — the suite did NOT fail on an assertion: it could not RESOLVE its import of the code under test (a module-resolution / load failure), so the test file never ran. The harness places your test IN THE REPO at its own test convention ($RED_GATE_CONVENTION) and runs it IN PLACE, right where the test sits — so import the code under test via a path that resolves FROM THERE: $imp_form. Re-author the import accordingly so the test LOADS, then FAILS on its assertions until the behaviour exists. ${hint}Command run: $cmd. Runner output (run):
$(printf '%s' "$out" | tail -20)"
      else
        reason="RED GATE — the quarantined suite did NOT fail on an assertion: it failed to COMPILE / LOAD (a SyntaxError, import/parse error, a load-time unresolved symbol, or a leftover placeholder token), so the test file never ran. A non-runnable contract cannot be handed to the Implementer (it must not edit the immutable tests to fix a syntax error). Re-author the test so it PARSES and LOADS cleanly, then FAILS on its assertions until the behaviour exists. Command run: $cmd. Runner output (quarantined run):
$(printf '%s' "$out" | tail -20)"
      fi
      printf '  ✗ %s\n' "$reason" >&2
      if [ -n "$RED_GATE_SIGNAL" ]; then
        {
          printf 'rc=%s (the quarantined-tests run failed to COMPILE/LOAD — NOT a valid assertion red)\n' "$rc"
          printf '%s\n' "$reason"
        } >"$RED_GATE_SIGNAL"
      fi
      return 1
    fi
    # The command reacted to the var → the non-zero exit is a genuine red of the
    # quarantined tests. Safe to hand off.
    return 0
  fi

  # GREEN against nothing. Before rejecting we diagnose WHY, so the signal tells
  # the next attempt whether the suite truly passed-on-nothing or the runner
  # simply ignored the quarantine. The probe above already ran.
  if [ "$ignored_var" = yes ]; then
    # Identical GREEN with NO quarantined tests present → the command did not react
    # to $LCARS_TESTS_DIR. It ran a fixed target (the repo's existing suite), so we
    # CANNOT prove the quarantined tests are what passed. BLOCK loud — never pass.
    reason="RED GATE — the configured test command exited 0 (green) but ALSO exits 0 with NO quarantined tests present, so it IGNORES \$LCARS_TESTS_DIR and ran the repo's EXISTING suite, not the quarantined tests. The harness cannot prove the new tests fail-first, so it refuses to hand them on. Command run: $cmd. Make \`testCommand\` honour \$LCARS_TESTS_DIR (run only that dir) — see \`lcars init\`."
  else
    # The runner reacted to the var (empty dir → different result) yet the quarantined
    # tests passed → a genuine green-on-nothing contract. Reject as proving nothing.
    reason="RED GATE — the quarantined suite PASSED with no implementation (exit 0). A contract that is green before anything is built proves nothing; the tests must FAIL first. Command run: $cmd. Runner output (quarantined run):
$(printf '%s' "$out" | tail -20)"
  fi
  printf '  ✗ %s\n' "$reason" >&2
  if [ -n "$RED_GATE_SIGNAL" ]; then
    {
      printf 'rc=%s (the quarantined-tests run exited 0 = GREEN, which the red gate rejects)\n' "$rc"
      printf '%s\n' "$reason"
    } >"$RED_GATE_SIGNAL"
  fi
  return 1
}

# S99: a PORTABLE hard wall-clock timeout (macOS has no coreutils `timeout`). Runs
# the given command with combined stdout+stderr captured to $2, returning the
# command's own rc — OR 124 (GNU-timeout's convention) if it exceeded $1 seconds
# and was killed. Launched as its own process-group leader (perl setsid, same trick
# as run_worker_hang_guarded) so a group-kill reaps children the runner forked
# (vitest/jest worker pools).
run_with_hard_timeout() { # secs  outfile  cmd...
  local secs="$1" outfile="$2"; shift 2
  case "$secs" in ''|*[!0-9]*) secs=120 ;; esac
  perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- "$@" >"$outfile" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 1 2>/dev/null || true
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1 2>/dev/null || waited="$secs"
    waited=$((waited + 1))
  done
  wait "$pid"
  return $?
}

# S99: did the runner FINISH but collect/run ZERO tests? Classify-only; never a
# red-gate verdict. Uses the rg_signature `zerotests` arm.
suite_collected_zero_tests() { # runner-output → 0 if zero tests were collected
  printf '%s' "$1" | grep -Eq "$(rg_signature zerotests)"
}

# S99: the Test-Writer PRE-GATE self-smoke VERDICT (pure). Given the timed run's rc
# and captured output, decide what the smoke does:
#   hang       — rc 124: the hard timeout fired (a never-settling awaited/thenable
#                mock, or an infinite async init) → Test-Writer defect (self-smoke bounces).
#   zero-tests — the suite finished but collected NO tests → Test-Writer defect (bounces).
#   ok         — everything else (a real run: red, green, OR a load/env failure) →
#                the self-smoke PROCEEDS and lets the authoritative red gate render the
#                verdict (it already rejects load/env/green with richer feedback).
# NOTE the deliberate split: load-error/env/green are NOT bounced by the smoke — the
# red gate is the single authority for those (avoids duplicating S95 feedback / a
# second weaker gate). The smoke ADDS only the two cases the gate cannot catch (a
# hang: no timeout; a zero-test suite: can slip through as a "valid red").
self_smoke_verdict() { # rc  runner-output → echoes hang|zero-tests|ok
  local rc="$1" out="$2"
  if [ "$rc" = 124 ]; then printf 'hang'; return 0; fi
  # A load/compile/resolution failure is the red gate's job (richer feedback) — do
  # NOT bounce it here; only fall through to the zero-tests check when it is NOT one.
  if red_gate_compile_failure "$out"; then printf 'ok'; return 0; fi
  if suite_collected_zero_tests "$out"; then printf 'zero-tests'; return 0; fi
  printf 'ok'
}

# S99: the actionable Test-Writer feedback for a bounced self-smoke. Written to the
# red-gate-signal.txt grounded-retry channel so the NEXT fresh Test-Writer attempt is
# told exactly what to fix; also becomes the last-attempt signal classify_impl_failure
# reads at exhaustion (the `hang` marker → the test-writer-hang category).
self_smoke_reason() { # verdict  cmd  runner-output
  local v="$1" cmd="$2" out="$3" tail
  tail="$(printf '%s' "$out" | tail -20)"
  case "$v" in
    hang)
      printf 'SELF-SMOKE — your suite HUNG: the suite never settled within the hard timeout when run before any implementation, so it produced no result. The usual cause is an AWAITED mock that never settles — e.g. a Proxy / catch-all host double whose `then` trap returns a callable makes the mock a THENABLE, so `await <mock>` waits forever. FIX: a Proxy / catch-all double MUST return `undefined` for `then` (and `catch` / `finally`), and NEVER `await` a synchronously-constructed mock object. Re-author so the suite COLLECTS and FAILS FAST on an assertion. Command run: %s. Runner output (self-smoke, killed at timeout):\n%s\n' "$cmd" "$tail" ;;
    zero-tests)
      printf 'SELF-SMOKE — your suite collected ZERO tests: no test case actually ran, so there is no red to hand off. Write at least one dedicated, fail-first test that INVOKES the not-yet-built behaviour through its public entrypoint and ASSERTS the observable output. Command run: %s. Runner output (self-smoke):\n%s\n' "$cmd" "$tail" ;;
  esac
}

# S99: run the authored suite ONCE, in the SAME (monorepo-aware) environment the
# red gate uses, under a HARD TIMEOUT, BEFORE the immutable snapshot. On a hang /
# zero-tests Test-Writer defect: write the reason to $sig (grounded-retry channel),
# roll back the quarantine ($tdir), and `die` → the Phase-1 loop retries the
# TEST-WRITER, never the Implementer, and nothing is snapshotted from a broken suite.
# A suite that RUNS (red/green/load-error) returns 0 and proceeds to the snapshot +
# the authoritative red gate. NEVER accepts anything the gate would reject.
# S101: runs the suite IN PLACE at its in-tree location (co-located `./sibling`
# imports resolve — NEVER copied into a quarantine/staging dir). `scope` is the
# in-tree file (or dir) to run, `run_dir` the cwd the runner is invoked from
# ($REPO_ROOT, or the sub-package dir for a monorepo ticket). On a failing verdict
# it writes the grounded-retry reason to $sig, prints the ✗ line, and RETURNS 1 —
# the caller rolls back the in-tree copies + quarantine mirror and dies (so a
# hanging / zero-test suite is never snapshotted and never reaches the Implementer).
test_writer_self_smoke() { # scope  run_dir  sig
  local scope="$1" run_dir="${2:-$REPO_ROOT}" sig="$3" cmd
  cmd="$(resolve_test_cmd)"
  if [ -z "$cmd" ]; then
    printf '  ⚠ SELF-SMOKE SKIPPED — no test command; cannot pre-run the suite (the red gate skips loud too).\n' >&2
    return 0
  fi
  local timeout_secs="${LCARS_SELF_SMOKE_TIMEOUT_SECS:-120}"
  local out; out="$(mktemp)"; local rc=0
  ( cd "$run_dir" && LCARS_TESTS_DIR="$scope" run_with_hard_timeout "$timeout_secs" "$out" bash -c "$cmd" ) || rc=$?
  local runner_out; runner_out="$(cat "$out" 2>/dev/null || true)"; rm -f "$out"
  local verdict; verdict="$(self_smoke_verdict "$rc" "$runner_out")"
  [ "$verdict" = ok ] && return 0
  local reason; reason="$(self_smoke_reason "$verdict" "$cmd" "$runner_out")"
  printf '%s' "$reason" >"$sig"
  printf '  ✗ SELF-SMOKE (%s): %s\n' "$verdict" "$reason" >&2
  return 1
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
# 0 if the ticket's tests still match the snapshot taken at impl-save-tests;
# non-zero if any test file was added, removed, or changed.
# S101: the snapshot records the IN-TREE relpaths (the test now lives in the repo
# tree, not a flat quarantine), so immutability is verified over the IN-TREE files
# under a given TREE — a post-snapshot edit to (or deletion of) the ridden-along
# test is caught exactly as an edit to the old quarantine copy was. Each snapshot
# line is "<hash>  <relpath>"; we re-hash <tree>/<relpath> and diff the snapshot.
# S102 (tests ride along, part 2): an optional second arg names the TREE ROOT to
# re-hash under (default $REPO_ROOT). This lets the SAME immutability check verify
# the COMMITTED test blob in a clean gate worktree (post-commit / pre-merge), so a
# weakened ridden-along test is caught ACROSS the commit boundary, not only in the
# Implementer's own scratch worktree.
tests_unchanged() { # ticketId  [tree-root]
  local snap cur h rel tree="${2:-$REPO_ROOT}"
  snap="$(ticket_dir "$1")/tests.sha256"
  [ -f "$snap" ] || return 1   # no snapshot → cannot prove unchanged → treat as a violation
  cur="$(mktemp)"; : >"$cur"
  while read -r h rel; do
    [ -n "$rel" ] || continue
    if [ -f "$tree/$rel" ]; then
      printf '%s  %s\n' "$(sha_of "$tree/$rel")" "$rel" >>"$cur"
    else
      printf 'MISSING  %s\n' "$rel" >>"$cur"   # deleted / moved → mismatch
    fi
  done <"$snap"
  if diff -q "$snap" "$cur" >/dev/null 2>&1; then rm -f "$cur"; return 0; fi
  rm -f "$cur"; return 1
}

# S102: the IN-TREE test relpaths recorded in a ticket's immutable snapshot (one
# per line). Mirrors tests_unchanged's read of "<hash>  <relpath>" — the relpath is
# everything after the first field. Used by the gates to scope the run to (and check
# for the committed presence of) exactly the locked test files.
snapshot_test_rels() { # ticketId  -> in-tree relpaths (newline)
  local snap h rel; snap="$(ticket_dir "$1")/tests.sha256"
  [ -f "$snap" ] || return 0
  while read -r h rel; do [ -n "$rel" ] && printf '%s\n' "$rel"; done <"$snap"
}

# S102: 0 iff EVERY snapshot test relpath exists as a real file under <tree> — i.e.
# the ticket's locked tests RODE ALONG committed and are present in this clean gate
# worktree (so the gate runs them IN PLACE instead of overlaying the mirror). Empty
# snapshot → non-zero (nothing committed to run in place). A branch-less / S101-era
# mission that never committed its tests returns non-zero → the overlay fallback.
tests_committed_in_tree() { # ticketId  tree
  local rel any=0 all=1
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    any=1
    [ -f "$2/$rel" ] || all=0
  done < <(snapshot_test_rels "$1")
  [ "$any" = 1 ] && [ "$all" = 1 ]
}

# --- GUARDRAIL 3: test quality (the suite must assert something) ------------
# Light, language-agnostic: reject a suite where no file contains any common
# assertion construct — an empty / zero-assertion / sandbagged contract proves
# nothing. The red gate catches a trivially-PASSING suite; this catches one that
# asserts nothing at all.
suite_has_assertions() { # tests-dir
  grep -rEiq 'assert|expect|should|\.to[A-Za-z]|require\(|t\.(is|deep|truthy|throws)|check\(|verify\(' "$1" 2>/dev/null
}

# --- GUARDRAIL 3.5: portable source location (BUG-074) ----------------------
# A ticket test that loads a repo source (e.g. game.js) via a HARDCODED ABSOLUTE
# build-worktree path — `fs.readFileSync('/private/var/worktrees/t-001/game.js')`
# — passes in the worktree it was authored in (the ticket goes green) but ENOENTs
# when the full-suite gate re-runs the suite from a CLEAN checkout elsewhere. That
# spurious "regression" triggers a futile (billed) implement self-heal and a
# confusing escalation, and the Implementer can NEVER fix it: the bad path lives
# in the immutable/locked test. The robust fix is to REJECT such a test before it
# locks in, so the Test Writer retries with a portable walk-up locator.
#
# `nonportable_path_in_tests` echoes the FIRST offending "<file>:<path>" and
# returns 0 (found) / 1 (clean). It is deliberately PRECISE so it does not
# false-positive on legitimate relative paths or on paths mentioned in comments:
#   • Only flags an ABSOLUTE path under a known non-portable, host-/run-specific
#     root: a `/private/var/` (or `/var/folders/`, `/private/var/folders/`) temp
#     path, a `…/worktrees/…` build-worktree segment, or an absolute `/Users/`
#     home path. A bare relative path (`../game.js`, `./fixtures/x`) is never
#     flagged.
#   • Only when that path is consumed by a path-OPENING construct on the same line
#     (readFileSync/readFile/createReadStream/openSync/require/import/fs.* path
#     args, or a Python open()/Path()) — not arbitrary string mentions.
#   • Skips lines that are pure comments (`//`, `#`, or `*` leader).
nonportable_path_in_tests() { # tests-dir → echoes "file:offending-path", rc 0 if found
  local d="$1"
  # The non-portable absolute roots that won't survive relocation. A path is one
  # of: /private/var/..., /var/folders/..., any .../worktrees/... segment, /Users/...
  local pathpat='(/private/var/[^"'"'"'`) ]+|/var/folders/[^"'"'"'`) ]+|/[^"'"'"'`) ]*/worktrees/[^"'"'"'`) ]+|/Users/[^"'"'"'`) ]+)'
  # A path-opening construct that consumes such a literal on the same line.
  local loadpat='(readFileSync|readFile|createReadStream|openSync|writeFileSync|require|import|fs\.[A-Za-z]+|path\.(resolve|join)|[^A-Za-z_]open|Path)\b'
  local rel hit
  while IFS= read -r rel; do
    rel="${rel#./}"
    # Strip pure-comment lines, then require BOTH a load construct AND a
    # non-portable absolute literal on the same surviving line.
    hit="$(grep -nE "$loadpat" "$d/$rel" 2>/dev/null \
            | grep -vE '^[0-9]+:[[:space:]]*(//|#|\*)' \
            | grep -oE "$pathpat" \
            | head -n1)"
    if [ -n "$hit" ]; then
      printf '%s:%s' "$rel" "$hit"
      return 0
    fi
  done < <(cd "$d" && find . -type f | LC_ALL=C sort)
  return 1
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

  # GUARDRAIL 3.5 (BUG-074): reject a NON-PORTABLE test before it locks in. A test
  # that loads a repo source via a hardcoded absolute build-worktree path passes in
  # the worktree it was authored in but ENOENTs from the full-suite gate, poisoning
  # it with a spurious regression the Implementer can never fix (the path lives in
  # the immutable test). Fail the attempt so the Test Writer retries portably.
  local bad_path; bad_path="$(nonportable_path_in_tests "$TESTS" || true)"
  [ -z "$bad_path" ] \
    || die "ticket test hardcodes an absolute path ${bad_path#*:} (in ${bad_path%%:*}) — tests must locate sources via the portable walk-up (e.g. a findGameJs() that walks up from __dirname), never an absolute build-worktree path; rejecting so the Test Writer retries."

  # S101 (tests ride along, part 1): the Test-Writer's fail-first test lands IN THE
  # REPO at the repo's OWN convention (co-located / __tests__/ / top-level tests/),
  # not only in the .git/lcars quarantine. We (a) detect the convention from the
  # repo, (b) map the ticket's target source to the in-tree test dir, and (c) write
  # each authored test file BOTH into the working tree ($REPO_ROOT/<relpath>, so the
  # red gate + Implementer run it IN PLACE and a later session can commit it by path)
  # AND into a MIRROR at tickets/<id>/tests/<relpath> whose relpaths equal the
  # in-tree relpaths — so the immutable snapshot records in-tree relpaths and every
  # downstream immutability re-check keys off the same path. Detection runs BEFORE we
  # write, so we never read back our own just-written test.
  local tdir; tdir="$(ticket_dir "$TICKET")/tests"
  local snap; snap="$(ticket_dir "$TICKET")/tests.sha256"
  local target_src; target_src="$(ticket_target_src "$TICKET" "$TESTS")"
  local convention; convention="$(detect_test_convention "$REPO_ROOT" "$target_src")"
  local fallback_src="${target_src:-src/index.ts}"
  # The ticket's package (monorepo-aware) — the RUN DIR for the in-place gate AND the
  # root the per-file sibling search prefers. Computed once, reused below.
  local pkg_rel; pkg_rel="$(ticket_target_package "$TICKET")"
  # The worker's scratch input dirs — NEVER resolve a sibling to a copy of the test or
  # stub living there (a mktemp OUTSIDE the repo in real use; pruned so a fixture that
  # nests them under the repo still resolves to the real in-tree source). Canonicalised
  # to PHYSICAL paths so the prune matches the physical paths `find $REPO_ROOT` yields
  # (macOS resolves /var → /private/var, so the raw arg would not prefix-match).
  local _sib_prune="" _sd
  for _sd in "$TESTS" "$STUBS"; do
    [ -n "$_sd" ] || continue
    [ -d "$_sd" ] && _sd="$(cd "$_sd" 2>/dev/null && pwd -P)"
    _sib_prune="${_sib_prune}${_sd}
"
  done

  # S101 (MULTI-DIR): a ticket can author SEVERAL test files whose sources live in
  # DIFFERENT dirs — so we place EACH file at ITS OWN co-located destination, not all
  # in one dir. For each authored test we (1) read the `./<sibling>` it imports, (2)
  # resolve that sibling to a real in-tree source (manifest → package/repo → the
  # ticket's primary source as fallback), and (3) map that source to the in-tree test
  # relpath at the repo convention. A SINGLE-FILE / single-dir ticket is byte-identical
  # to before (all files map to one dir).
  rm -rf "$tdir"; mkdir -p "$tdir"
  local INTREE_RELS="" f bn stem src_f canon_f destdir_f reldir rel
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    bn="${f##*/}"
    stem="$(test_primary_sibling "$f")"
    src_f="$(resolve_sibling_src "$stem" "$TICKET" "$fallback_src" "$pkg_rel" "$_sib_prune")"
    canon_f="$(test_path_for "$convention" "$src_f")"
    destdir_f="${canon_f%/*}"; [ "$destdir_f" = "$canon_f" ] && destdir_f=""
    rel="${destdir_f:+$destdir_f/}$bn"
    reldir="${rel%/*}"; [ "$reldir" = "$rel" ] && reldir=""
    [ -n "$reldir" ] && { mkdir -p "$tdir/$reldir" 2>/dev/null || :; mkdir -p "$REPO_ROOT/$reldir" 2>/dev/null || :; }
    cp "$f" "$tdir/$rel"
    cp "$f" "$REPO_ROOT/$rel"
    INTREE_RELS="${INTREE_RELS}${rel}
"
  done < <(find "$TESTS" -type f | LC_ALL=C sort)

  # Roll the in-tree test copies AND any overlaid greenfield stubs back out of the
  # working tree — used on every rejection path so a suite that fails the self-smoke
  # / red gate leaves NO trace behind (and a retry that emits no stub still reds on
  # RESOLUTION rather than tripping over a leftover stub). STUB_RELS is populated by
  # the stub-overlay block below (empty until then).
  local STUB_RELS=""
  _impl_rollback_intree() {
    local r
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      rm -f "$REPO_ROOT/$r"
      rmdir -p "$REPO_ROOT/${r%/*}" 2>/dev/null || :   # prune now-empty dirs, best-effort
    done <<ROLLBACK_EOF
$INTREE_RELS
$STUB_RELS
ROLLBACK_EOF
  }

  # The IN-PLACE scope the self-smoke + red gate run against: the single in-tree test
  # file when there is exactly one (precise positional filter), else the deepest COMMON
  # ANCESTOR dir of the placed files (so a multi-dir ticket's gate covers every file —
  # e.g. `src` for tests in src/utils + src/canvas + src/components/MapCanvas). When all
  # files share one dir the ancestor IS that dir, byte-identical to the old behaviour.
  # NOTE: a common-ancestor scope may also run PRE-EXISTING tests under that ancestor
  # (green on a clean base) — acceptable: the new red still fails the suite, and the
  # red gate's empty-dir PROBE still isolates the new red (a runner ignoring
  # $LCARS_TESTS_DIR is still BLOCKED). Absolute so the runner relativizes from any dir.
  local n_tests; n_tests="$(printf '%s' "$INTREE_RELS" | grep -c . || true)"
  local scope_rel
  if [ "$n_tests" -eq 1 ]; then scope_rel="$(printf '%s' "$INTREE_RELS" | grep . | head -1)"
  else scope_rel="$(common_ancestor_dir "$INTREE_RELS")"; fi
  local scope_abs="$REPO_ROOT${scope_rel:+/$scope_rel}"

  # S94 (greenfield stubs): a ticket that creates a BRAND-NEW source module can't
  # pass the red gate today — the Test-Writer's import of the not-yet-existent module
  # cannot RESOLVE, so 0 tests collect and the gate rejects it as a resolution-failure
  # red. To "make it compile first" (what a human does), the Test-Writer ALSO emits a
  # MINIMAL EMPTY stub for any module its tests import that does not exist yet, under
  # a `stubs/` tree. OVERLAY that tree onto the worktree source HERE — BEFORE the red
  # gate — so the import resolves and the suite reds on a real ASSERTION (a valid red).
  # S101: the test now runs IN PLACE at the repo's convention, so a co-located
  # `./<sibling>` import resolves next to the RELOCATED test — NOT at a repo-mirrored
  # path the Test-Writer would have to guess. S101 (MULTI-DIR): each greenfield stub
  # must land next to ITS OWN test — the dir where that test's `./<sibling>` resolves —
  # NOT all stubs in one dir. A stub is named for its module stem, so we resolve THAT
  # stem the same way the test placement did (manifest → package/repo → primary source
  # fallback) and place the stub in the resolved SOURCE dir — the identical dir its
  # matching test was co-located into. For __tests__ the source sits one level up from
  # the test (the module's own dir = the resolved source dir); for top-level tests/ the
  # import is package-root-relative, so we keep the mirrored repo path. Nested imports
  # (`./a/b`) degrade to basename — documented limitation. The stubs are scaffolding
  # the Implementer OVERWRITES: they are NOT
  # snapshotted (not in tests.sha256, not in $tdir) and are LEFT in place on SUCCESS;
  # on REJECTION they are rolled back with the tests (STUB_RELS). With no stubs the
  # behaviour is byte-identical to before — a still-missing module reds with the
  # resolution-failure reason. S99: overlaid BEFORE the snapshot so BOTH the pre-gate
  # self-smoke and the red gate resolve greenfield imports against the same stubs.
  if [ -n "$STUBS" ] && [ -d "$STUBS" ] \
     && [ -n "$(find "$STUBS" -type f -print -quit 2>/dev/null)" ]; then
    local srel sstem ssrc sbase dest ddir
    while IFS= read -r srel; do
      srel="${srel#./}"; [ -n "$srel" ] || continue
      case "$convention" in
        tests) dest="$srel" ;;   # top-level tests/: keep the mirrored repo relpath
        *)     # co-located / __tests__: resolve the stub's own stem → its source dir.
          sstem="${srel##*/}"; sstem="${sstem%.*}"
          ssrc="$(resolve_sibling_src "$sstem" "$TICKET" "$fallback_src" "$pkg_rel" "$_sib_prune")"
          sbase="${ssrc%/*}"; [ "$sbase" = "$ssrc" ] && sbase=""
          dest="${sbase:+$sbase/}${srel##*/}"
          ;;
      esac
      ddir="${dest%/*}"; [ "$ddir" = "$dest" ] && ddir=""
      [ -n "$ddir" ] && { mkdir -p "$REPO_ROOT/$ddir" 2>/dev/null || :; }
      cp "$STUBS/$srel" "$REPO_ROOT/$dest"
      STUB_RELS="${STUB_RELS}${dest}
"
    done < <(cd "$STUBS" && find . -type f | LC_ALL=C sort)
  fi

  # S99: the grounded-retry signal file + the RUN DIR the in-place gate cd's into
  # ($pkg_rel, computed once above, is the monorepo package root so config/discovery
  # resolves there); the tests run co-located in the tree, NOT copied into a quarantine.
  local run_dir="$REPO_ROOT"; [ -n "$pkg_rel" ] && run_dir="$REPO_ROOT/$pkg_rel"
  local sig; sig="$(ticket_dir "$TICKET")/red-gate-signal.txt"; rm -f "$sig"

  # S99 PRE-GATE SELF-SMOKE (BEFORE the immutable snapshot / handoff): bounce a
  # hanging or zero-test suite back to the TEST-WRITER (retry) so the Implementer
  # never burns attempts on it and a hang never wedges the ticket. A suite that runs
  # (red/green/load-error) proceeds to the snapshot + the authoritative red gate.
  # S101: run IN PLACE at the in-tree scope (co-located imports resolve). On a
  # failing verdict, roll the in-tree copies + mirror back out and die.
  if ! test_writer_self_smoke "$scope_abs" "$run_dir" "$sig"; then
    _impl_rollback_intree; rm -rf "$tdir" "$snap"
    local why=""; [ -f "$sig" ] && why="
$(cat "$sig")"
    die "the Test Writer's suite failed the pre-gate self-smoke — a hanging or empty suite must never reach the Implementer; retrying the Test Writer.$why"
  fi

  # GUARDRAIL 2 setup: snapshot the in-tree test files (via the mirror, whose
  # relpaths equal the in-tree relpaths) so impl-save-result can prove the
  # Implementer never edited the locked contract. AFTER the self-smoke so a hanging /
  # zero-test suite is never snapshotted. The snapshot records IN-TREE relpaths.
  snapshot_tests "$tdir" "$snap"

  # GUARDRAIL 1 (the red gate): the suite must FAIL against no implementation before
  # the Implementer is allowed to run. A green-on-nothing suite is rejected and the
  # in-tree copies + mirror are rolled back, so nothing reaches the Implementer. We
  # CAPTURE the rejection reason (rc + bounded runner output + which-suite diagnosis)
  # to a durable signal file so (a) the human sees WHY instead of a silent stall, and
  # (b) the next grounded Test-Writer attempt can be told what went wrong.
  # S101: the gate runs IN PLACE — LCARS_TESTS_DIR points at the in-tree test scope
  # under $REPO_ROOT and the runner is invoked from $run_dir (the package root for a
  # monorepo ticket). NOTHING is copied into <pkg>/__lcarsq__: a co-located test that
  # imports `./<sibling>` resolves against the real source next to it. The empty-dir
  # PROBE inside red_gate_ok still runs the SAME command with an EMPTY dir, so a
  # runner that ignores $LCARS_TESTS_DIR is still BLOCKED (probe discrimination
  # preserved). An empty pkg_rel runs from $REPO_ROOT, as before.
  local red_rc=0
  RED_GATE_SIGNAL="$sig" RED_GATE_CONVENTION="$convention" red_gate_ok "$scope_abs" "$run_dir" || red_rc=$?
  if [ "$red_rc" -ne 0 ]; then
    _impl_rollback_intree; rm -rf "$tdir" "$snap"
    local why=""; [ -f "$sig" ] && why="
$(cat "$sig")"
    die "the Test Writer's suite did not pass the red gate — a contract that is green (or unprovable) before anything is built proves nothing; the tests must FAIL first.$why"
  fi
  rm -f "$sig"

  # S102 (tests ride along, part 2): COMMIT the locked test in its OWN commit BEFORE
  # the Implementer runs, so it merges into the PR — WITHOUT handing the Implementer an
  # editable test (it stages ONLY the snapshotted test file(s), explicitly; the stubs
  # and every other change stay uncommitted). Worktree mode records .test-commit-sha
  # for the parent to cherry-pick JUST BEFORE the impl commit; a branch-less mission
  # SKIPS the commit and keeps S101 behaviour. When we did NOT commit (no branch, or a
  # defensive skip) we fall back to S101: record the in-tree relpath(s) in
  # .untracked-before so commit_ticket treats them as PRE-EXISTING untracked and NEVER
  # stages them onto the branch. When we DID commit, the test is now tracked and
  # unchanged, so commit_ticket's `git add -u` is a no-op for it (immutability is
  # re-verified at ticket-green and pre-merge against the COMMITTED blob).
  commit_locked_tests "$TICKET"
  if [ "$COMMIT_TESTS_NOTE" != "committed" ]; then
    local ub; ub="$(ticket_dir "$TICKET")/.untracked-before"
    [ -n "$INTREE_RELS" ] && printf '%s' "$INTREE_RELS" | grep -v '^$' >>"$ub" 2>/dev/null || :
  fi

  echo "IMPLEMENT: tests saved — $TICKET"
  echo "  Saved $count Test Writer file(s) at the repo's test convention ($convention): ${scope_rel:-<repo root>}."
  echo "  Red gate: suite fails as required; the contract is locked (immutable)."
  if [ "$COMMIT_TESTS_NOTE" = "committed" ]; then
    echo "  Test committed (rides along into the PR) BEFORE the Implementer; the contract is committed + locked."
  fi
  exit 0
}

# --- GUARDRAIL 5: the post-commit verification (BUG-017) --------------------
# The adversarial Implementer often builds in its OWN ephemeral per-ticket git
# worktree ($LCARS_TICKET_WORKTREE) or a scratch tree, then self-reports
# passed:true. commit_ticket assembles the ticket's scoped diff onto the mission
# branch (normal mode) or a detached commit at the branch tip (worktree mode,
# cherry-picked later). NOTHING re-checked that the change actually LANDED on the
# committed branch state: a worker can pass green in its scratch tree while the
# commit holds only an out-of-scope edit (or no change at all), and the harness
# would still emit ticket_green and advance to Verify on that worktree-only green.
# That is the literal BUG-017 dual-CLI defect (version.sh present under one CLI,
# absent under another, same Mission).
#
# This gate closes the hole. Run IMMEDIATELY AFTER commit_ticket, it re-runs the
# ticket's OWN quarantined suite against a CLEAN checkout of the COMMITTED state —
# never the Implementer's scratch worktree:
#   • worktree mode  → the commit object commit_ticket recorded to .commit-sha
#                      (or, if it committed nothing, the worktree's unchanged tip
#                      → the change is NOT present → the suite must go red).
#   • normal mode    → the mission branch HEAD.
# A clean detached worktree is cut at that commit-ish and the suite is staged at a
# DEPTH-1 dir there (mirroring full_suite_gate), so relative-to-self target
# resolution behaves exactly as at green-time. The ticket PASSES only when the
# suite is GREEN on the committed state; a RED there means the implementation
# never landed (or only an out-of-scope change was committed) and the attempt
# FAILS — routed into the SAME retry/flag path as any other failed attempt.
# Purely ADDITIVE: it weakens neither the red gate, the immutable-test snapshot,
# the test-quality check, nor the full-suite gate. With NO runner configured it
# SKIPS LOUD (never a false pass, never a false fail), matching the other gates;
# a branch-less / local-only mission has no committed branch to check, so it keeps
# the current behaviour rather than crash.
POST_COMMIT_SIGNAL=""   # caller may point this at a file to capture the failure detail
post_commit_gate() { # ticket
  local t="$1" cmd; cmd="$(resolve_test_cmd)"
  if [ -z "$cmd" ]; then
    # NO RUNNER: the same documented degradation as the red / full-suite gates.
    # We cannot re-run the suite against the committed branch, so we SKIP LOUD —
    # never a false pass, and never a false FAIL of a runner-less repo.
    printf '  ⚠ POST-COMMIT GATE SKIPPED — no test command (set `testCommand` in .git/lcars/config.json or $LCARS_TEST_CMD). The harness cannot re-verify the ticket landed GREEN on the committed branch without a runner; configure one to close this gap.\n' >&2
    return 0
  fi

  # Resolve the commit-ish that represents the COMMITTED state for this ticket.
  local ref=""
  if [ -n "${LCARS_TICKET_WORKTREE:-}" ]; then
    # Worktree mode: commit_ticket committed onto the detached HEAD and recorded
    # the commit object to .commit-sha. If it committed nothing (no file changes),
    # .commit-sha is absent and the worktree HEAD is the UNCHANGED branch tip — the
    # change is not present, so verifying there correctly goes red.
    ref="$(cat "$(ticket_dir "$t")/.commit-sha" 2>/dev/null || true)"
    [ -n "$ref" ] || ref="$("$GIT_BIN" -C "$LCARS_TICKET_WORKTREE" rev-parse HEAD 2>/dev/null || true)"
  else
    local branch; branch="$(json_str "$STATE" branch)"
    # Branch-less / local-only mission → no committed branch to check. Keep the
    # current behaviour (the gate does not apply) rather than crash.
    [ -n "$branch" ] && "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch" || return 0
    ref="$("$GIT_BIN" rev-parse "refs/heads/$branch" 2>/dev/null || true)"
  fi
  # Defensive: nothing resolvable to check (e.g. an unborn ref) — do not crash and
  # do not invent a failure. Keep current behaviour.
  [ -n "$ref" ] || return 0

  # Cut a CLEAN detached worktree at the committed commit-ish — NEVER the
  # Implementer's scratch worktree (so uncommitted scratch-only files are invisible).
  #
  # CONCURRENCY (BUG-017): an Implement wave builds its tickets in PARALLEL, every
  # sibling running its own post_commit_gate against the SAME shared MISSION_DIR.
  # Each ticket MUST therefore own a PRIVATE, UNIQUE worktree path and only ever
  # create / remove THAT path — never a shared parent dir, and never a global
  # `git worktree prune` (which would unregister a sibling's in-use worktree). A
  # unique mktemp -d name guarantees no two concurrent gates collide.
  local wt; wt="$(mktemp -d "$MISSION_DIR/postcommit-${t}.XXXXXX" 2>/dev/null || true)"
  [ -n "$wt" ] || wt="$MISSION_DIR/postcommit-${t}.$$"
  rm -rf "$wt"
  if ! "$GIT_BIN" worktree add -q --detach "$wt" "$ref" >/dev/null 2>&1; then
    # Could not cut a worktree (defensive) — never false-fail; keep current behaviour.
    # Remove ONLY this ticket's own worktree; never touch siblings.
    "$GIT_BIN" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt" 2>/dev/null || :
    return 0
  fi
  # Session 81: provision the fresh post-commit worktree ONCE, before its testCommand
  # re-runs, so it evaluates in the same dependency-complete environment as the red /
  # full-suite gates. Best-effort: a failure breadcrumbs but never aborts the gate.
  provision_worktree "$wt" || :

  # S102 (tests ride along, part 2) — the tests are now COMMITTED alongside the source,
  # so in the common path they are ALREADY PRESENT in this clean worktree. Two changes
  # over S101's blanket overlay:
  #   (a) CROSS-BOUNDARY IMMUTABILITY: before running, re-hash the COMMITTED test blob
  #       against the locked snapshot (tests_unchanged over $wt). A mismatch = the
  #       ridden-along test was weakened after it was locked → a TAMPERING violation,
  #       returned as a DISTINCT code (4) so cmd_impl_save_result routes it like any
  #       immutable-test violation (loud BLOCK), never a normal red / self-heal.
  #   (b) OVERLAY RECONCILE: only OVERLAY the mirror when the test is NOT committed in
  #       the tree (a branch-less / S101-era mission) — never overlay-then-remove a
  #       file that is already committed (that would delete a committed file). When the
  #       test IS committed we run it IN PLACE at its committed path (no overlay, no
  #       removal) and scope $LCARS_TESTS_DIR to the snapshot relpaths.
  # S87: a sub-package ticket runs vitest/jest FROM its package root (run_dir=<wt>/<pkg>)
  # for discovery/config; an empty pkg_rel runs from the worktree root.
  local pkg_rel; pkg_rel="$(ticket_target_package "$t" "$wt")"
  local run_dir tdir rc=0 out="" rels scope tamper=0
  run_dir="$wt"; [ -n "$pkg_rel" ] && run_dir="$wt/$pkg_rel"
  tdir="$(ticket_dir "$t")/tests"
  if [ -d "$tdir" ]; then
    if tests_committed_in_tree "$t" "$wt"; then
      # Committed (S102): verify the COMMITTED blob is still the locked snapshot.
      if tests_unchanged "$t" "$wt"; then
        rels="$(snapshot_test_rels "$t")"
        scope="$(intree_scope_for "$wt" "$rels")"
        out="$( cd "$run_dir" && LCARS_TESTS_DIR="$scope" bash -c "$cmd" 2>&1 )" || rc=$?
      else
        tamper=1
        local tdetail="POST-COMMIT GATE — LOCKED-TEST TAMPERING: ticket $t's COMMITTED test file no longer matches its immutable snapshot (tests.sha256). The ridden-along test was weakened after it was locked; refusing. This is NOT a normal red and is NOT self-healable — the adversarial/immutable contract was violated across the commit boundary. Restore the locked test or re-open the ticket."
        printf '  ✗ %s\n' "$tdetail" >&2
        [ -n "$POST_COMMIT_SIGNAL" ] && printf '%s\n' "$tdetail" >"$POST_COMMIT_SIGNAL"
      fi
    else
      # S101 fallback (branch-less / uncommitted): OVERLAY the mirror, run, remove.
      # A co-located `./<sibling>` import resolves against the real source next to it.
      rels="$(overlay_intree_tests "$tdir" "$wt")"
      scope="$(intree_scope_for "$wt" "$rels")"
      # If nothing was overlaid, NEVER run against an empty suite and false-GREEN.
      if [ -n "$(printf '%s' "$rels" | grep . || true)" ]; then
        out="$( cd "$run_dir" && LCARS_TESTS_DIR="$scope" bash -c "$cmd" 2>&1 )" || rc=$?
      fi
      remove_overlaid_tests "$wt" <<REMOVE_EOF
$rels
REMOVE_EOF
    fi
  fi

  # Clean up ONLY this ticket's own worktree on EVERY exit path — never leak into
  # the captain's `git worktree list`, and never remove a shared dir or prune
  # globally (a sibling ticket may be mid-run in the same MISSION_DIR).
  "$GIT_BIN" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt" 2>/dev/null || :

  # S102: a tampered COMMITTED test blocks with a DISTINCT code, ahead of the normal
  # env/red verdicts (the signal was already written above).
  [ "$tamper" = 1 ] && return 4

  [ "$rc" -eq 0 ] && return 0

  # S84 (gate-worktree-deps): CLASSIFY a runner-STARTUP failure distinctly from a
  # genuine missing-implementation red. If the test runner ITSELF could not launch
  # in the gate worktree (no node_modules/venv, an absent test binary, no lockfile —
  # a `command not found` class failure), the suite is RED for an ENVIRONMENT reason,
  # NOT because the implementation is absent — so the misleading "not present on the
  # committed branch" wording would send the captain hunting a non-existent code bug.
  # Report the env-unprovisioned diagnosis and signal it with a DISTINCT return code
  # (3) so the call site emits the right event. We use red_gate_env_failure ONLY
  # (never red_gate_compile_failure): a genuinely-absent implementation legitimately
  # yields a module/compile error from the test FILE, which IS the missing-impl case
  # and must keep its existing wording. This is diagnosis only — the attempt STILL
  # fails (never a red flipped to green).
  if red_gate_env_failure "$out"; then
    local edetail="POST-COMMIT GATE — environment not provisioned — the test runner could not start in the gate worktree (missing node_modules/venv or an absent test binary); set \`worktreeSetupCommand\` in .git/lcars/config.json (see \`lcars update\`). This is NOT a missing implementation. Command run: $cmd."
    printf '  ✗ %s\n' "$edetail" >&2
    [ -n "$POST_COMMIT_SIGNAL" ] && printf '%s\n' "$edetail" >"$POST_COMMIT_SIGNAL"
    return 3
  fi

  local detail="POST-COMMIT GATE — ticket $t's suite is RED against the COMMITTED branch state (commit ${ref}). The implementation is NOT present on the committed branch: the Implementer reported green from its OWN scratch worktree, but the change never landed (or only an out-of-scope change was committed). The ticket FAILS this attempt — it must land its change on the committed branch to pass. Command run: $cmd."
  printf '  ✗ %s\n' "$detail" >&2
  [ -n "$POST_COMMIT_SIGNAL" ] && printf '%s\n' "$detail" >"$POST_COMMIT_SIGNAL"
  return 1
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

  # GUARDRAIL 5 (BUG-017): the worker self-reported passed:true, possibly from its
  # OWN ephemeral scratch worktree. Re-verify the ticket's suite against the CLEAN
  # COMMITTED branch state — a worktree-only green (or an out-of-scope-only commit)
  # must NEVER advance to Verify. A RED on the committed branch FAILS this attempt:
  # drop the just-saved (not-actually-green) result so the ticket never counts as
  # green, emit the harness's own event, and `die` so the Implementer loop retries
  # exactly as for any other failed attempt (the same retry/flag path).
  local pcsig; pcsig="$(ticket_dir "$TICKET")/post-commit-signal.txt"; rm -f "$pcsig"
  local pcrc=0; POST_COMMIT_SIGNAL="$pcsig" post_commit_gate "$TICKET" || pcrc=$?
  if [ "$pcrc" -ne 0 ]; then
    local why=""; [ -f "$pcsig" ] && why="
$(cat "$pcsig")"
    rm -f "$pcsig"
    rm -f "$(ticket_dir "$TICKET")/result.json"   # not green on the branch — never let it count
    case "$pcrc" in
      3)
        # S84 (gate-worktree-deps): the gate could not even START the test runner in
        # the gate worktree — the environment is UN-PROVISIONED, NOT a missing
        # implementation. Emit a DISTINCT event and die with the env-grounded reason
        # ($why now carries the worktreeSetupCommand wording). The attempt STILL fails.
        emit_event ticket_env_unprovisioned implement \
          "ticket $TICKET — environment not provisioned (the test runner could not start in the gate worktree); set worktreeSetupCommand in .git/lcars/config.json" \
          "ticket=$TICKET" "attempts=$attempts"
        die "ticket $TICKET could not be re-verified — the test runner could not start in the gate worktree (environment not provisioned); this is NOT a missing implementation. Set worktreeSetupCommand in .git/lcars/config.json.$why"
        ;;
      4)
        # S102 (tests ride along): the COMMITTED locked test no longer matches its
        # immutable snapshot — the ridden-along contract was WEAKENED across the commit
        # boundary. Route it exactly like the in-worktree immutable-tests violation: a
        # distinct event + a loud die. Green must be earned by implementing, never by
        # weakening the test — even after it rides along committed.
        emit_event ticket_locked_test_tampered implement \
          "ticket $TICKET — committed locked test no longer matches the immutable snapshot (tampering detected across the commit boundary)" \
          "ticket=$TICKET" "attempts=$attempts"
        die "ticket $TICKET — LOCKED-TEST TAMPERING: the COMMITTED test file no longer matches its immutable snapshot. Green must be earned by implementing, never by weakening the ridden-along contract. Rejected by the cross-boundary immutable-tests guardrail.$why"
        ;;
      *)
        emit_event ticket_postcommit_red implement \
          "ticket $TICKET failed the post-commit check — implementation not present on the committed branch" \
          "ticket=$TICKET" "attempts=$attempts"
        die "ticket $TICKET reported green but its suite is RED against the COMMITTED branch state — the implementation is not present on the committed branch (worktree-only green or out-of-scope commit). Result rejected by the post-commit guardrail.$why"
        ;;
    esac
  fi
  rm -f "$pcsig"

  # The change is confirmed present and GREEN on the committed branch — record the
  # successful post-commit verification so the stream / `--watch` view show it.
  emit_event ticket_postcommit_ok implement \
    "ticket $TICKET verified green on the committed branch" \
    "ticket=$TICKET" "attempts=$attempts"

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

# --- GUARDRAIL 4: the full-suite regression gate (BUG-013) ------------------
# Every per-ticket gate (ticket_green, the wave loop, the impl-advance precheck)
# only ever checks each ticket's OWN quarantined suite. Nothing re-runs ALL the
# accumulated ticket suites TOGETHER against the fully-built repo, so a LATER
# ticket can satisfy its own suite (green) while REGRESSING an EARLIER ticket's
# locked contract on the same input — and because no gate re-runs the earlier
# suite, the wave completes "green" with the regression invisible.
#
# This gate closes that hole. Run at the Verify precheck AFTER every ticket is
# individually green, it re-runs EVERY completed ticket's quarantined suite
# against the current (fully-built) repo, reusing the red gate's runner contract:
# the configured testCommand run from $REPO_ROOT with $LCARS_TESTS_DIR pointing at
# the ticket's quarantined tests (the runner honours that var as of BUG-009). A
# ticket's suite is "still green" iff its run exits 0; any earlier suite that is
# no longer green is a regression a LATER ticket introduced. It is purely ADDITIVE
# — it does not weaken the per-ticket red/green gate, the immutable-test snapshot,
# or the test-quality check. With NO runner configured it SKIPS LOUD (never a
# false pass and never a false fail), matching the red gate's no-runner stance.
# --- SHARED: re-run every named ticket's quarantined suite against a given tree -
# Extracted from full_suite_gate (BUG-013) so BOTH the full-suite gate AND the
# S76 reconcile gate re-test ticket suites the SAME way: stage each ticket's
# `tests/` at a DEPTH-1 dir under the run tree (so a test that resolves its target
# relative to its own location finds it at the repo root, exactly as at green-time),
# then run the configured testCommand from that tree with $LCARS_TESTS_DIR pointing
# at the staged dir. $run_dir is the tree to run against (a worktree at the branch
# tip for the gate, the reconcile merge worktree for the reconcile). On any per-
# ticket non-zero exit the ticket id is appended to the global $RETEST_FAILED list,
# and (when $RETEST_CAPTURE is set) its combined stdout/stderr is captured to
# $RETEST_CAPTURE/<id>.log so the reconcile author can quote the failure. Returns 0
# iff every suite passed. $RETEST_FAILED / $RETEST_FAILED is reset by the caller.
# S101 (tests ride along): a ticket's tests are MIRRORED at their IN-TREE relpaths
# ($tdir has the in-tree relpath layout). To re-run one against a CLEAN worktree
# (post-commit / full-suite / reconcile) where the test is NOT committed, OVERLAY it
# onto the tree at its in-tree relpath — co-located with that tree's committed
# source — so a co-located `./<sibling>` import resolves against the real source
# next to it, NOT a detached copy (which the S101 spike proved breaks the import).
# Echoes the overlaid relpaths (one per line) for scoping + removal.
overlay_intree_tests() { # tdir  tree  -> echoes overlaid relpaths (newline)
  local tdir="$1" tree="$2" rel
  [ -d "$tdir" ] || return 0
  while IFS= read -r rel; do
    rel="${rel#./}"; [ -n "$rel" ] || continue
    mkdir -p "$tree/${rel%/*}" 2>/dev/null || :
    cp "$tdir/$rel" "$tree/$rel"
    printf '%s\n' "$rel"
  done < <(cd "$tdir" && find . -type f | LC_ALL=C sort)
}
# Remove ONLY the relpaths this run overlaid (never a committed file we didn't add).
remove_overlaid_tests() { # tree  <<< rels
  local tree="$1" rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rm -f "$tree/$rel"; rmdir -p "$tree/${rel%/*}" 2>/dev/null || :
  done
}
# The absolute $LCARS_TESTS_DIR scope for the overlaid relpaths: the single file when
# there is exactly one (precise positional filter), else the deepest COMMON ANCESTOR
# dir of the overlaid files — SAME rule as the in-place gate in cmd_impl_save_tests, so
# a ticket whose tests span multiple dirs re-tests symmetrically here (post-commit /
# full-suite / reconcile). Empty rels → the tree itself.
intree_scope_for() { # tree  rels(newline)
  local tree="$1" rels="$2" n first ca
  n="$(printf '%s' "$rels" | grep -c . || true)"
  first="$(printf '%s' "$rels" | grep . | head -1)"
  [ -n "$first" ] || { printf '%s' "$tree"; return; }
  if [ "$n" -eq 1 ]; then printf '%s/%s' "$tree" "$first"
  else
    ca="$(common_ancestor_dir "$rels")"
    printf '%s%s' "$tree" "${ca:+/$ca}"
  fi
}

RETEST_FAILED=""     # space-separated ticket ids that failed the last retest
RETEST_TAMPERED=""   # S102: ids whose COMMITTED test no longer matches the snapshot
RETEST_CAPTURE=""    # caller may point this at a dir to capture per-ticket output
retest_ticket_suites() { # run_dir  cmd  ordered ticketId...
  local run_dir="$1" cmd="$2"; shift 2
  RETEST_FAILED=""
  RETEST_TAMPERED=""
  local id tdir rc out pkg_rel trun rels scope
  for id in "$@"; do
    [ -n "$id" ] || continue
    tdir="$(ticket_dir "$id")/tests"
    # Defensive: a green ticket should always have a saved suite. If one is missing
    # we skip it rather than crash — we never INVENT a failure.
    [ -d "$tdir" ] || continue
    # S87: PER-TICKET, a sub-package ticket re-runs INSIDE its own package (vitest/
    # jest discover & filter at the package root); an empty pkg_rel runs from the
    # run-tree root. Checked against $run_dir so every caller (full-suite gate
    # worktree, reconcile merge worktree) stays symmetric.
    pkg_rel="$(ticket_target_package "$id" "$run_dir")"
    trun="$run_dir"; [ -n "$pkg_rel" ] && trun="$run_dir/$pkg_rel"
    rc=0
    # S102 (tests ride along, part 2): the tests are COMMITTED, so in the common path
    # they are ALREADY present in this clean tree. PRE-MERGE CROSS-BOUNDARY IMMUTABILITY:
    # before running, re-hash the COMMITTED test blob against the locked snapshot. A
    # mismatch = the ridden-along test was weakened after locking → BLOCK LOUD (this is
    # not a regression to self-heal; the Mission must NOT merge a weakened test). We
    # `die` here so EVERY caller — the full-suite gate AND the reconcile — stops with the
    # tampering reason rather than proceeding to merge or self-heal.
    if tests_committed_in_tree "$id" "$run_dir"; then
      if ! tests_unchanged "$id" "$run_dir"; then
        RETEST_TAMPERED="${RETEST_TAMPERED:+$RETEST_TAMPERED }$id"
        emit_event ticket_locked_test_tampered implement \
          "ticket $id — committed locked test no longer matches the immutable snapshot (pre-merge tamper check)" \
          "ticket=$id" || :
        die "PRE-MERGE LOCKED-TEST TAMPERING: ticket $id's COMMITTED test no longer matches its immutable snapshot (tests.sha256) — the ridden-along contract was weakened after it was locked. BLOCKED: the Mission cannot merge a weakened test, and this is NOT a self-healable regression. Restore the locked test or re-open the ticket."
      fi
      # Committed + intact → run IN PLACE at the committed path (no overlay, no removal).
      rels="$(snapshot_test_rels "$id")"
      scope="$(intree_scope_for "$run_dir" "$rels")"
      out="$( cd "$trun" && LCARS_TESTS_DIR="$scope" bash -c "$cmd" 2>&1 )" || rc=$?
    else
      # S101 fallback (branch-less / uncommitted): OVERLAY the ticket's in-tree tests
      # onto the clean tree (co-located with the committed source), run, then remove
      # exactly them.
      rels="$(overlay_intree_tests "$tdir" "$run_dir")"
      scope="$(intree_scope_for "$run_dir" "$rels")"
      out="$( cd "$trun" && LCARS_TESTS_DIR="$scope" bash -c "$cmd" 2>&1 )" || rc=$?
      remove_overlaid_tests "$run_dir" <<REMOVE_EOF
$rels
REMOVE_EOF
    fi
    if [ "$rc" -ne 0 ]; then
      RETEST_FAILED="${RETEST_FAILED:+$RETEST_FAILED }$id"
      [ -n "$RETEST_CAPTURE" ] && { mkdir -p "$RETEST_CAPTURE"; printf '%s\n' "$out" >"$RETEST_CAPTURE/$id.log"; }
    fi
  done
  [ -z "$RETEST_FAILED" ]
}

FULL_SUITE_SIGNAL=""   # caller may point this at a file to capture the regression detail
full_suite_gate() { # ordered ticketId...
  local cmd; cmd="$(resolve_test_cmd)"
  if [ -z "$cmd" ]; then
    # NO RUNNER: the same documented degradation as the red gate. We cannot
    # re-check earlier tickets for regressions, so we SKIP LOUD — never a false
    # pass, and (critically) never a false FAIL of a runner-less repo.
    printf '  ⚠ FULL-SUITE GATE SKIPPED — no test command (set `testCommand` in .git/lcars/config.json or $LCARS_TEST_CMD). The harness cannot re-run earlier tickets to catch a cross-ticket regression without a runner; configure one to close this gap.\n' >&2
    return 0
  fi
  # BUG-013 (the false-regression defect): a ticket's quarantined suite was
  # green-validated against a tree where the built code sits at the repo root and
  # the test file sits at a DEPTH-1 dir (`tests/`), so a portable test that
  # resolves its target relative to its OWN location — e.g.
  # `bash "$(dirname "${BASH_SOURCE[0]}")/../skills/foo.sh"` — finds it at
  # `<root>/skills/foo.sh`. Re-running that same test from the DETACHED quarantine
  # dir `tickets/<id>/tests/` makes `$here/..` resolve to `tickets/<id>/`, NOT the
  # repo root, so the target is "not found" and the test exits non-zero — a FALSE
  # regression. To re-run each suite in the SAME condition it was locked under, we
  # cut ONE clean detached worktree at the mission-branch tip (all tickets' code
  # present) and stage each ticket's tests at a DEPTH-1 dir under that worktree
  # root via the shared retest_ticket_suites helper (also used by the reconcile).
  local branch; branch="$(json_str "$STATE" branch)"
  local wt_base="$MISSION_DIR/fullsuite-wt" wt=""
  wt="$(make_ticket_worktree "$wt_base" "$branch" "all")"
  local regressed=""
  # BUG-018/BUG-019: capture each failing suite's runner output so we can tell a
  # mock/harness TypeError (an incomplete per-ticket test double — a harness gap)
  # apart from a real assertion failure. The capture dir is scanned below and
  # discarded; it never leaks.
  local cap; cap="$MISSION_DIR/.fullsuite-cap"; rm -rf "$cap"
  if [ -n "$wt" ]; then
    # WORKTREE MODE: a real mission branch exists. Re-run each suite from the clean
    # tip via the shared helper, so relative-to-self target resolution behaves as
    # it did at green-time.
    RETEST_CAPTURE="$cap" retest_ticket_suites "$wt" "$cmd" "$@" || regressed="$RETEST_FAILED"
    # Clean up the worktree on EVERY exit path — never leak into the captain's
    # `git worktree list` or working tree. Mirrors cleanup_ticket_worktrees.
    "$GIT_BIN" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    "$GIT_BIN" worktree prune >/dev/null 2>&1 || :
    rm -rf "$wt_base" 2>/dev/null || :
  else
    # FALLBACK (no mission branch — a branch-less / local-only mission): keep the
    # original in-tree behaviour, running each suite from $REPO_ROOT.
    RETEST_CAPTURE="$cap" retest_ticket_suites "$REPO_ROOT" "$cmd" "$@" || regressed="$RETEST_FAILED"
  fi
  if [ -z "$regressed" ]; then rm -rf "$cap" 2>/dev/null; return 0; fi

  # S84 (gate-worktree-deps): before attributing a cross-ticket REGRESSION, classify
  # whether the suites failed because the test RUNNER could not START in the gate
  # worktree (an UN-PROVISIONED environment — no node_modules/venv, an absent test
  # binary) rather than a real code regression. Mirror the BUG-019 capture scan:
  # concatenate the captured failing-suite output and run the env-failure detector
  # (red_gate_env_failure, narrowly scoped to runner-startup signatures). On a match,
  # report the env-unprovisioned diagnosis (naming worktreeSetupCommand) INSTEAD of
  # the misleading regression wording, and emit a distinct ticket_env_unprovisioned
  # event (best-effort, like the TypeError note). The gate STILL returns non-zero —
  # this is diagnosis only, never a fail flipped to a pass.
  if [ -d "$cap" ]; then
    local _envout=""; _envout="$(cat "$cap"/*.log 2>/dev/null)"
    if red_gate_env_failure "$_envout"; then
      local edetail="FULL-SUITE GATE — environment not provisioned — the test runner could not start in the gate worktree (missing node_modules/venv or an absent test binary), so earlier ticket suite(s) could not be re-run against the fully-built repo. This is NOT a cross-ticket regression. Set \`worktreeSetupCommand\` in .git/lcars/config.json (see \`lcars update\`). Command run: $cmd."
      emit_event ticket_env_unprovisioned implement \
        "full-suite gate — environment not provisioned (the test runner could not start in the gate worktree); set worktreeSetupCommand in .git/lcars/config.json" || :
      rm -rf "$cap" 2>/dev/null
      printf '  ✗ %s\n' "$edetail" >&2
      [ -n "$FULL_SUITE_SIGNAL" ] && printf '%s\n' "$edetail" >"$FULL_SUITE_SIGNAL"
      return 1
    fi
  fi

  local detail="FULL-SUITE GATE — these earlier ticket suite(s) no longer pass against the fully-built repo: ${regressed}. Each was green when built, so a LATER ticket's produced code REGRESSED its locked contract. The Mission is NOT shippable until the regression is resolved (fix the later ticket or re-open the regressed ticket). Command run: $cmd."
  # Harness-gap detection (BUG-019): if any captured failing-suite output mentions a
  # TypeError / undefined-method surface, this is very likely an INCOMPLETE per-ticket
  # MOCK (an earlier ticket's headless browser/host double lacks a method a later
  # ticket's code legitimately calls) rather than a real assertion failure. Flag that
  # in the detail so the captain knows completing the mock may be the fix, not
  # weakening an assertion. Pure string scan over the captured output — best-effort.
  if [ -d "$cap" ] && grep -RqiE 'TypeError|is not a function|is not defined|undefined is not' "$cap" 2>/dev/null; then
    detail="$detail

NOTE: a failing suite's output mentions a TypeError / undefined surface — this often means a per-ticket test MOCK is incomplete (a HARNESS GAP, not a real assertion failure: see BUG-019). Completing the earlier ticket's mock (stub the missing method, or share one defensive per-mission double) may be the fix, rather than weakening an assertion."
  fi
  rm -rf "$cap" 2>/dev/null
  printf '  ✗ %s\n' "$detail" >&2
  [ -n "$FULL_SUITE_SIGNAL" ] && printf '%s\n' "$detail" >"$FULL_SUITE_SIGNAL"
  return 1
}

# --- BUG-027: translate internal t-XXX ticket ids → GitHub issue language ----
# The human-facing copy must speak the board's language. Given a space-separated
# list of internal ticket ids, echo a human string mapping each to its GitHub
# issue number (#N, via the Schedule-written waves.json issue field) — or, when a
# ticket has no mapped issue, to its plan title (never the raw t-XXX). Used to
# build humanSummary; the raw t-XXX stays only in technicalDetail.
tickets_to_issues() { # ticketId...
  local waves="$MISSION_DIR/waves.json" plan="$MISSION_DIR/approved-plan.json"
  local out="" id issue title piece
  for id in "$@"; do
    [ -n "$id" ] || continue
    issue=""
    [ -f "$waves" ] && issue="$(ticket_issue "$waves" "$id")"
    case "$issue" in
      ''|null) issue="" ;;
    esac
    if [ -n "$issue" ]; then
      piece="issue #$issue"
    else
      title=""
      [ -f "$plan" ] && title="$(ticket_title "$plan" "$id" 2>/dev/null || true)"
      if [ -n "$title" ]; then piece="\"$title\""; else piece="$id"; fi
    fi
    out="${out:+$out, }$piece"
  done
  printf '%s' "$out"
}

# Pull a ticket's title from a plan/approved-plan.json (jq-free) for the t-XXX
# fallback above. Best-effort; empty when not found.
ticket_title() { # plan.json  ticketId
  awk -v want="$2" '
    /"id"[[:space:]]*:/    { n=split($0,a,"\""); if (n>=4) cur=a[4]; next }
    /"title"[[:space:]]*:/ { if (cur==want) {
        v=$0; sub(/.*"title"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v)
        print v; exit } }
  ' "$1"
}

# --- BUG-027: clean, legible escalation of a full-suite regression ----------
# Mirrors the BUG-018 awaiting-human escalation (validate-pause shape), but ALSO
# writes the structured fields the viewscreen consumes: a plain-language
# humanSummary in GitHub-issue language (t-XXX translated), escalationType=
# "regression", and the verbatim raw reason as technicalDetail (where t-XXX may
# remain). The existing question text is preserved for back-compat. Reached only
# AFTER self-heal exhausts its cap (genuinely irreducible).
escalate_full_suite_regression() { # reason  ordered ticketId...
  local reason="$1"; shift
  local ordered="$*"
  # The regressing (just-built, latest-in-plan-order) ticket and, when the gate
  # named the regressed earlier suites, those tickets — translated to issue #s.
  local regressor=""; for regressor in $ordered; do :; done   # last id in plan order
  local regressed_ids; regressed_ids="$(printf '%s\n' "$reason" \
    | sed -n 's/.*no longer pass against the fully-built repo: \([^.]*\)\..*/\1/p' | head -1)"
  local victims; victims="$(tickets_to_issues $regressed_ids)"
  local culprit; culprit="$(tickets_to_issues "$regressor")"
  local summary
  if [ -n "$victims" ]; then
    summary="Two changes conflict — the fix for $culprit re-broke a test from $victims. Reply with how to reconcile them, send the mission back to re-fix, or drop one."
  else
    summary="A change conflicts with the rest of the branch and the harness could not auto-reconcile it. Reply with how to reconcile, or send the mission back to re-fix."
  fi

  local q; q="$(mktemp)"
  printf '%s\n' "$reason" >"$q"
  LCARS_PENDING_HUMAN_SUMMARY="$summary" \
  LCARS_PENDING_ESCALATION_TYPE="regression" \
  LCARS_PENDING_TECHNICAL_DETAIL="$reason" \
    write_pending "$q" "implement"
  rm -f "$q"
  state_set_raw awaitingHuman true
  state_set_str pendingQuestion "$summary"
  # In-flight stage label (implement) first, THEN the awaiting-human overlay, so
  # the parked card sits squarely in the Implement column (mirror validate-pause).
  gh_relabel "lcars:implement lcars:awaiting-human" ""

  emit_event gate implement "full-suite regression — self-heal exhausted, awaiting your answer: $summary" \
    "phase=full-suite-gate"

  echo "IMPLEMENT: full-suite regression — self-heal exhausted, flagged the human"
  printf '%s\n' "$summary"
  echo "  Stage: implement (awaiting-human). Resolve with \`lcars respond $MISSION_ID\`."
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
}

# --- BUG-029: self-heal a full-suite regression before escalating -----------
# Auto-iterate the implementer of the regressing (latest-in-plan-order) ticket
# with a harness-authored reconcile instruction, re-running the full-suite gate
# after each attempt, up to a cap. Reuses the EXISTING implement-ticket
# re-dispatch + LCARS_REUSE_TESTS path (the locked tests stay immutable — only the
# Implementer re-runs), mirroring the S76 reconcile / same-file rebuild loops.
# Returns 0 once every suite passes again (healed), non-zero when the cap is hit
# (caller escalates). The last failing reason is written to $SELFHEAL_LAST_REASON.
SELFHEAL_CAP="${LCARS_SELFHEAL_CAP:-3}"
case "$SELFHEAL_CAP" in ''|*[!0-9]*) SELFHEAL_CAP=3 ;; esac
SELFHEAL_LAST_REASON=""
self_heal_full_suite() { # reason  ordered ticketId...
  local reason="$1"; shift
  local ordered="$*"
  SELFHEAL_LAST_REASON="$MISSION_DIR/selfheal-last-reason.txt"
  printf '%s\n' "$reason" >"$SELFHEAL_LAST_REASON"

  # The regressing ticket is the latest one built (last in plan order).
  local regressor=""; for regressor in $ordered; do :; done
  [ -n "$regressor" ] || return 1

  # Resolve the worktree base + branch the same way cmd_implement's rebuild does so
  # the re-dispatched implementer composes on the CURRENT mission-branch tip.
  local branch; branch="$(json_str "$STATE" branch)"
  local wt_base="$MISSION_DIR/selfheal-wt"

  local round=0 fssig
  while [ "$round" -lt "$SELFHEAL_CAP" ]; do
    round=$((round + 1))
    emit_event selfheal implement "self-heal round $round/$SELFHEAL_CAP — re-running $regressor's implementer to reconcile the regression" \
      "ticket=$regressor" "round=$round"

    # Re-dispatch ONLY the regressing ticket's Implementer with the reconcile
    # feedback. LCARS_REUSE_TESTS keeps the locked tests immutable (Phase 1 is
    # skipped), so only production code can change — never the contract.
    local irc=0
    rm -f "$(ticket_dir "$regressor")/.build-rc" "$(ticket_dir "$regressor")/.commit-sha" 2>/dev/null
    LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" \
    LCARS_TICKET_WT_BASE="$wt_base" LCARS_TICKET_BRANCH="$branch" LCARS_REUSE_TESTS=1 \
    LCARS_SELFHEAL_FEEDBACK="$(cat "$SELFHEAL_LAST_REASON")" \
      bash "$SELF" implement-ticket --mission "$MISSION_ID" --ticket "$regressor" >/dev/null 2>&1 || irc=$?

    # A flagged ticket (its own 5-attempt cap) set awaitingHuman in shared state —
    # the per-ticket attempt cap already handled it; stop self-healing here.
    if [ "$(json_raw "$STATE" awaitingHuman)" = "true" ]; then
      emit_event selfheal implement "self-heal round $round flagged the ticket's own attempt cap — stopping self-heal" \
        "ticket=$regressor" "round=$round"
      return 1
    fi

    # Cherry-pick the rebuild's fresh commit onto the mission branch (the worktree
    # build committed on a detached HEAD), exactly like the same-file rebuild path,
    # so the full-suite gate re-runs against the integrated tip.
    local sha; sha="$(cat "$(ticket_dir "$regressor")/.commit-sha" 2>/dev/null || true)"
    if [ -n "$sha" ] && [ -n "$branch" ] && "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
      "$GIT_BIN" -C "$REPO_ROOT" checkout -q "$branch" 2>/dev/null || :
      "$GIT_BIN" -C "$REPO_ROOT" cherry-pick "$sha" >/dev/null 2>&1 \
        || "$GIT_BIN" -C "$REPO_ROOT" cherry-pick --abort >/dev/null 2>&1 || :
    fi

    # Re-run the full-suite gate. Green → healed.
    fssig="$MISSION_DIR/full-suite-signal.txt"; rm -f "$fssig"
    if FULL_SUITE_SIGNAL="$fssig" full_suite_gate $ordered; then
      rm -f "$fssig"
      emit_event selfheal_ok implement "self-heal succeeded in round $round — every suite passes again" \
        "ticket=$regressor" "round=$round"
      return 0
    fi
    [ -f "$fssig" ] && cp "$fssig" "$SELFHEAL_LAST_REASON"
    rm -f "$fssig"
  done

  emit_event selfheal_exhausted implement "self-heal exhausted $SELFHEAL_CAP round(s) — regression is irreducible, escalating" \
    "ticket=$regressor" "rounds=$SELFHEAL_CAP"
  return 1
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

  local w id ordered=""
  while IFS=$'\t' read -r w id; do
    [ -n "$id" ] || continue
    ticket_green "$id" \
      || die "ticket $id (wave $w) is not green yet — every ticket must pass before Verify. Run \`lcars run $MISSION_ID\` to finish the open waves."
    ordered="${ordered:+$ordered }$id"
  done <<EOF
$table
EOF

  # GUARDRAIL 4 (BUG-013): every ticket is individually green, but that only
  # proves each ticket's OWN suite passes. Re-run EVERY completed ticket's
  # quarantined suite together against the fully-built repo to catch a later
  # ticket that regressed an earlier ticket's locked contract. Refuse Verify on
  # any regression, naming the regressed earlier ticket.
  local fssig; fssig="$MISSION_DIR/full-suite-signal.txt"; rm -f "$fssig"
  if ! FULL_SUITE_SIGNAL="$fssig" full_suite_gate $ordered; then
    local reason="a cross-ticket regression was detected by the full-suite gate"
    [ -f "$fssig" ] && reason="$(cat "$fssig")"
    rm -f "$fssig"

    # BUG-029: SELF-HEAL BEFORE escalating. A full-suite regression is a
    # MECHANICALLY-RECONCILABLE failure — a later ticket's change broke an earlier
    # ticket's locked contract — exactly the kind of fix an implementer can be told
    # to make (the captain otherwise hand-types "reconcile so test T passes; don't
    # touch the locked contract"). So auto-iterate the implementer of the regressing
    # (just-built, latest-in-plan-order) ticket with that harness-authored feedback,
    # re-run the full-suite gate, and only escalate to the human AFTER the cap. This
    # reuses the SAME implement-ticket re-dispatch + LCARS_REUSE_TESTS machinery the
    # S76 reconcile / same-file rebuild already drive (the locked tests stay
    # immutable — only the Implementer re-runs). The full-suite gate (BUG-013) is
    # never weakened: it must still pass for the loop to clear.
    if self_heal_full_suite "$reason" $ordered; then
      # Healed: every suite passes again. Advance to Verify (fall through below).
      reason=""
    else
      # Cap exhausted → genuinely irreducible. Escalate cleanly (BUG-018 path) with
      # BUG-027's structured, legible fields.
      reason="$(cat "$SELFHEAL_LAST_REASON" 2>/dev/null || printf '%s' "$reason")"
      escalate_full_suite_regression "$reason" $ordered
      exit 0
    fi
  fi
  rm -f "$fssig"

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
  echo "    lcars approve $MISSION_ID    — merge the PR (ship it)"
  echo "    lcars feedback $MISSION_ID   — send back with feedback"
  exit 0
}

# === open-pr (S75): Verify AUTO-OPENS the PR =================================
# When the driver reaches Verify with no PR yet, it opens the PR by REUSING the
# shared pr-lib.sh open_pr (the same title/body/manifest builders approve used
# to carry), records prUrl/prNumber + a `review:"open"` sub-state into state.json,
# and stays at the verify stage — the Mission is "in review — PR open", NOT Done.
# Idempotent: a recorded prUrl means open_pr returns the existing URL and opens
# no second PR. Degrades gracefully: any precondition failure `die`s (non-zero,
# no review marker) so a card never reads "in review" with no PR behind it.
#
#   open-pr  --mission <id>
cmd_open_pr() {
  locate_mission "$MISSION_ID"
  require_stage verify

  # BUG-026: a Mission-Log bug child (parentMission set) FOLDS its fix onto the
  # PARENT Mission's branch — the parent's PR carries it; the bug has NO PR of its
  # own. Only TOP-LEVEL Missions open a PR. So for a parentMission mission, skip
  # the PR-open entirely (no pr_opened, no degraded gate) — resolve-logs drives it
  # to the parent's single consolidated re-verify gate.
  local parent; parent="$(json_str "$STATE" parentMission)"
  if [ -n "$parent" ] && [ "$parent" != "null" ]; then
    echo "OPEN-PR: skipped — Mission-Log bug child (parent $parent); its fix folds onto the parent's branch (no per-bug PR)."
    exit 0
  fi

  # The PR-open library lives with approve (its other consumer). After
  # ./install.sh both skills are symlinked siblings; $LCARS_PR_LIB overrides the
  # path so tests can point at the source tree.
  local pr_lib="${LCARS_PR_LIB:-$SKILL_DIR/../lcars-approve/pr-lib.sh}"
  [ -f "$pr_lib" ] || die "pr-lib.sh not found at $pr_lib — cannot open the PR."
  # shellcheck source=skills/lcars-approve/pr-lib.sh
  . "$pr_lib"

  BRANCH="$(json_str "$STATE" branch)"
  BASE="$(json_str "$STATE" base)"; BASE="${BASE:-main}"

  # Already recorded? Idempotent — open_pr returns the existing URL, opens none.
  local existing; existing="$(json_str "$STATE" prUrl)"
  case "$existing" in
    http*|*/pull/*)
      echo "OPEN-PR: already open — $existing"
      exit 0 ;;
  esac

  open_pr   # sets PR_URL, records prUrl/prNumber; dies on any precondition fail.

  # Record the in-review sub-state so the board shows "in review — PR open".
  state_set_str review "open"
  emit_event pr_opened verify "PR opened — $PR_URL"

  echo "OPEN-PR: opened — $PR_URL"
  echo "  Stage:  verify (in review — PR open)"
  exit 0
}

# === S76: main-ahead reconcile + self-heal =================================
# Before Verify opens the PR, integrate like a real engineer: if the mission
# branch's base (main) has MOVED AHEAD since the branch was cut, MERGE the updated
# base into the branch in an ISOLATED worktree, re-run the mission's OWN ticket
# suites against the combined state, and — if anything breaks (textual conflict OR
# a silent logical conflict the re-test catches) — self-dispatch detailed Mission
# Log(s) authored from the failure and drive the fixes onto the branch through the
# EXISTING lcars log → resolve-logs → complete machinery, iterating to green. Only
# once green-against-updated-main does Verify proceed to open the PR. After K rounds
# still red → escalate (awaiting-human). NEVER opens a PR on a stale-and-broken
# branch. Reuse, don't fork.
RECONCILE_MAX="${LCARS_RECONCILE_MAX:-3}"
case "$RECONCILE_MAX" in ''|*[!0-9]*) RECONCILE_MAX=3 ;; esac

# Resolve the base ref to merge from, preferring the remote-tracking ref (best-
# effort fetched first). Echoes the ref (empty = unresolvable).
reconcile_base_ref() { # BASE BRANCH (in caller scope)
  "$GIT_BIN" fetch origin "$BASE" --quiet 2>/dev/null || true
  if "$GIT_BIN" show-ref --verify --quiet "refs/remotes/origin/$BASE"; then
    printf 'refs/remotes/origin/%s' "$BASE"
  elif "$GIT_BIN" show-ref --verify --quiet "refs/heads/$BASE"; then
    printf 'refs/heads/%s' "$BASE"
  fi
}

# The ordered green tickets whose suites we re-test (waves order = plan order).
reconcile_ordered_tickets() {
  local waves="$MISSION_DIR/waves.json" table w id ordered=""
  [ -f "$waves" ] || return 0
  table="$(parse_waves_table "$waves")"
  while IFS=$'\t' read -r w id; do
    [ -n "$id" ] && ordered="${ordered:+$ordered }$id"
  done <<EOF
$table
EOF
  printf '%s' "$ordered"
}

# Author detailed bug PRD(s) from the failure summary via a cold worker on the
# mission's OWN engine, then route them through log.sh → resolve-logs drive →
# resolve-logs complete. $1 = the failure-summary text. Echoes nothing; returns 0.
# Set by reconcile_author_and_dispatch when the author judged the conflict an
# UNRESOLVABLE design trade-off and authored an experience-framed QUESTION instead
# of a self-heal — the gate then escalates with this text (BUG-042). Empty = the
# author dispatched a normal self-heal.
RECONCILE_DESIGN_QUESTION=""

# BUG-056 — CONVERGE a TEXTUAL merge conflict by KEEPING a resolved merge.
# The merge worktree ($wt) holds the conflicted merge (markers present). Dispatch a
# cold resolve worker (mission's own engine) to edit the conflicted file(s) IN $wt
# so every conflict marker is gone — composing BOTH intents, honouring the captain's
# decision in answers.json if present (BUG-042 parity). After each attempt, verify
# no markers remain AND the mission's own ticket suites re-test GREEN against the
# resolved tree; if so, COMPLETE the merge commit in $wt (the branch ref advances to
# the merged+resolved commit) and return 0 — converged. If still conflicted/red
# after MAX_WORKER_TRIES, return 1 so the caller falls through to the existing RED
# undo+escalation path (round cap / design question — no infinite loop).
# Args: $wt  base_ref  failure-summary  affected-block  cmd  ordered-tickets...
reconcile_resolve_in_worktree() {
  local wt="$1" base_ref="$2" summary="$3" affected="$4" cmd="$5"; shift 5
  local ordered="$*"

  # The conflicted files, as absolute paths inside the worktree, for the worker.
  local conflicted_now; conflicted_now="$( cd "$wt" && "$GIT_BIN" diff --name-only --diff-filter=U 2>/dev/null )"
  [ -n "$conflicted_now" ] || return 1
  local abs_list="" cf
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    abs_list="$abs_list
- $wt/$cf"
  done <<EOF
$conflicted_now
EOF

  # The mission's own engine (BUG-D parity with the heal author).
  local engine; engine="$(json_str "$STATE" workerBin)"
  [ -n "$engine" ] || engine="$WORKER_BIN"

  local sumfile; sumfile="$MISSION_DIR/reconcile-failure.txt"
  printf '%s\n' "$summary" >"$sumfile"
  local extra="## The conflicted files to RESOLVE IN PLACE (absolute paths in the merge worktree)
Edit each of these files so EVERY conflict marker (<<<<<<<, =======, >>>>>>>) is gone:$abs_list

$affected

The deterministic failure summary (with the conflict hunks) is at:
- $sumfile

## The two intents to reconcile
- This mission's goal/PRD: $MISSION_DIR/prd.md
- What changed on the base branch since this branch was cut is quoted in the summary above."

  # RESUME after `lcars respond` (BUG-042/043 parity): inject the captain's decision
  # so the resolution implements EXACTLY their choice rather than re-guessing. Prefer
  # the DEDICATED reconcile answer (BUG-043); fall back to the generic answers.json
  # only when no dedicated answer exists.
  local cap_answer=""
  if [ -s "$MISSION_DIR/reconcile-answer.txt" ]; then
    cap_answer="$(cat "$MISSION_DIR/reconcile-answer.txt")"
  elif [ -f "$MISSION_DIR/answers.json" ]; then
    cap_answer="$(json_str "$MISSION_DIR/answers.json" answer)"
  fi
  if [ -n "$cap_answer" ]; then
    extra="$extra

## The captain DECIDED the design trade-off — implement EXACTLY this
A prior reconcile pass raised a design question to the captain; they answered:

  The captain decided: $cap_answer

This is a DECISION, not a new option to weigh. Resolve the conflict to implement
EXACTLY that arrangement."
  fi

  state_set_str reconcileStatus "resolving"
  emit_event reconcile_resolve verify "resolving textual conflict in place via a cold worker (keeping the merge)"

  local tries=0 odir
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    # The worker edits files in $wt directly; $odir is its (unused) scratch channel.
    odir="$(mktemp -d)"
    LCARS_WORKER_BIN="$engine" LCARS_WORKER_INPUT_DIRS="$wt
$MISSION_DIR" \
      spawn_worker reconcile-resolve "$STAGES_DIR/reconcile-resolve.md" repo-write "$odir" "$extra"
    rm -rf "$odir"

    # STAGE the worker's edits FIRST: editing a conflicted working-tree file does NOT
    # clear its UNMERGED index entry, so `git add -A` is what marks the conflict
    # resolved. Then judge resolution by CONTENT — any conflict marker still in an
    # originally-conflicted file means the worker did not finish; retry (or fall
    # through after the cap). This never relies on --diff-filter=U post-edit.
    ( cd "$wt" && "$GIT_BIN" add -A >/dev/null 2>&1 ) || :
    local markers=0 mf marker_files=""
    while IFS= read -r mf; do
      [ -n "$mf" ] || continue
      if grep -Eq '^(<<<<<<< |={7}$|>>>>>>> )' "$wt/$mf" 2>/dev/null; then
        markers=1
        marker_files="${marker_files:+$marker_files }$mf"
      fi
    done <<EOF
$conflicted_now
EOF
    if [ "$markers" -ne 0 ]; then
      # DURABLE WHY (BUG-057 / BUG-051 parity): the worker ran but did NOT finish —
      # conflict markers REMAIN in $marker_files. Record it before retrying so the
      # cause is not ephemeral. Purely additive; the `continue` below is unchanged.
      reconcile_resolve_record "$tries" "markers-remain in $marker_files" \
        "Conflict markers (<<<<<<< / ======= / >>>>>>>) still present after the resolve worker ran in: $marker_files"
      continue   # markers remain — retry (or fall through after the cap)
    fi

    # Markers gone (and staged) → re-test the resolved worktree.
    local green=1
    local red_suites="" red_tail=""
    if [ -n "$cmd" ] && [ -n "$ordered" ]; then
      local cap; cap="$(mktemp -d)"
      RETEST_CAPTURE="$cap" retest_ticket_suites "$wt" "$cmd" $ordered || green=0
      if [ "$green" -ne 1 ]; then
        # Capture WHICH suite(s) went red + the tail of each captured log BEFORE the
        # capture dir is removed (BUG-057). RETEST_FAILED holds the failing ticket ids.
        red_suites="$RETEST_FAILED"
        local rid
        for rid in $RETEST_FAILED; do
          if [ -s "$cap/$rid.log" ]; then
            red_tail="$red_tail
--- suite $rid (last ~40 lines) ---
$(tail -n 40 "$cap/$rid.log" 2>/dev/null)"
          fi
        done
      fi
      rm -rf "$cap"
    fi
    if [ "$green" -eq 1 ]; then
      # KEEP the merge: complete the merge commit so the branch ref advances to the
      # merged+resolved commit (mirrors the GREEN path, where the merge auto-commits).
      ( cd "$wt" && "$GIT_BIN" commit --no-edit >/dev/null 2>&1 ) || :
      emit_event reconcile_resolved verify "textual conflict resolved + re-test green — keeping the merge"
      return 0   # converged
    fi
    # DURABLE WHY (BUG-057): markers were cleared but the re-test stayed RED. Record
    # the red suite name(s) + their output tail before retrying. Purely additive.
    reconcile_resolve_record "$tries" "retest red — suite(s): ${red_suites:-unknown}" \
      "Markers cleared but re-test RED.
Failing suite(s): ${red_suites:-unknown}${red_tail}"
    # Resolved but red — let the worker try again (a cleaner composition) up to the cap.
  done
  return 1   # could not resolve+green within the cap → caller takes the RED path
}

# DURABLE instrumentation for the in-worktree resolve path (BUG-057, BUG-051 parity):
# append a timestamped, attempt-scoped record to $MISSION_DIR/reconcile-resolve.log
# (append, never overwrite) AND emit a reconcile_resolve_failed event with a short,
# NON-generic reason, on EACH failed resolve attempt. Purely additive — changes no
# control flow / outcome; it only ensures the cause is not silently discarded.
reconcile_resolve_record() { # attempt  short-reason  detail-block
  local attempt="$1" reason="$2" detail="$3"
  [ -n "${MISSION_DIR:-}" ] && {
    printf '%s\tattempt=%s\treason=%s\n%s\n----8<----\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" \
      "$attempt" "$reason" "$detail" \
      >>"$MISSION_DIR/reconcile-resolve.log" 2>/dev/null || :
  }
  emit_event reconcile_resolve_failed verify \
    "resolve attempt $attempt failed: $reason" "attempt=$attempt"
}

reconcile_author_and_dispatch() { # failure-summary  affected-block
  local summary="$1" affected="$2"
  RECONCILE_DESIGN_QUESTION=""
  state_set_str reconcileStatus "healing"
  emit_event reconcile_heal verify "authoring self-heal bug PRD(s) from the merge failure"

  # The mission's own engine (BUG-D): a copilot mission self-heals on copilot. Feed
  # it to the author worker AND to log.sh so each child inherits it.
  local engine; engine="$(json_str "$STATE" workerBin)"
  [ -n "$engine" ] || engine="$WORKER_BIN"

  # Cold-worker authoring: feed ONLY the failure summary + the two intents (this
  # mission's PRD goal + what changed on main), assembled from PATHS like the other
  # stages. The worker writes bug-NNN.md files into the scratch dir.
  local sumfile; sumfile="$MISSION_DIR/reconcile-failure.txt"
  printf '%s\n' "$summary" >"$sumfile"
  local extra="## The merge-failure summary (your ONLY inputs)
$affected

The deterministic failure summary is at:
- $sumfile

## The two intents to reconcile
- This mission's goal/PRD: $MISSION_DIR/prd.md
- What changed on the base branch since this branch was cut is quoted in the summary above."

  # RESUME after `lcars respond` (BUG-042/043): if the captain already answered a
  # prior RECONCILE design-trade-off escalation, INJECT that decision so the heal
  # implements exactly what they chose (do NOT re-raise the same question). The
  # answer comes from the DEDICATED reconcile store (reconcile-answer.txt) — NOT the
  # generic answers.json, which respond writes for ANY awaiting-human gate and could
  # be a stale, unrelated decision (BUG-043). Consumed below after one use.
  local recon_ans=""
  if [ -s "$MISSION_DIR/reconcile-answer.txt" ]; then
    recon_ans="$(cat "$MISSION_DIR/reconcile-answer.txt")"
    if [ -n "$recon_ans" ]; then
      extra="$extra

## The captain DECIDED the design trade-off — implement EXACTLY this
A prior reconcile pass raised a design question to the captain; they answered:

  The captain decided: $recon_ans

This is a DECISION, not a new option to weigh. Author the self-heal bug PRD(s)
that implement EXACTLY that arrangement — do NOT re-raise the question, and do NOT
emit a design-question file this time."
    fi
  fi

  local odir tries=0 prior_no_file=""
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    odir="$(mktemp -d)"
    LCARS_WORKER_BIN="$engine" \
      spawn_worker reconcile-author "$STAGES_DIR/reconcile-author.md" repo-read "$odir" "$extra" "$prior_no_file"
    # The author may judge the conflict an UNRESOLVABLE design trade-off and write
    # an experience-framed QUESTION (design-question.txt) instead of bug PRDs. If so,
    # surface it for the gate to escalate — UNLESS the captain has already answered
    # THIS reconcile's design question (a dedicated reconcile answer is in hand) and
    # we are now implementing their decision. Gate on the DEDICATED reconcile answer
    # (recon_ans), NOT the generic answers.json (BUG-043: an unrelated prior gate's
    # answer must never suppress this design question).
    if [ -s "$odir/design-question.txt" ] && [ -z "$recon_ans" ]; then
      RECONCILE_DESIGN_QUESTION="$(cat "$odir/design-question.txt")"
      rm -rf "$odir"
      return 0
    fi
    # collect the authored PRDs
    local prds=() f
    for f in "$odir"/bug-*.md; do
      [ -f "$f" ] || continue
      grep -q '^# Mission:' "$f" || continue
      grep -q '\*\*Type:\*\*' "$f" || continue
      # copy to a stable path under the mission dir so log.sh reads a durable file
      local dst; dst="$MISSION_DIR/reconcile-bug-$(basename "$f")"
      cp "$f" "$dst"
      prds+=("$dst")
    done
    if [ "${#prds[@]}" -gt 0 ]; then
      prior_no_file=""
      # Route through the Mission Log: one --prd per bug. BUG-D stamps each child's
      # workerBin from $LCARS_WORKER_BIN; log.sh fast-tracks to Plan, links the
      # parent, and (BUG-011) commits the fixes onto the parent's pre-merge branch.
      local prd_args=() p
      for p in "${prds[@]}"; do prd_args+=(--prd "$p"); done
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" LCARS_WORKER_BIN="$engine" \
        bash "$LOG_SCRIPT" --parent "$MISSION_ID" "${prd_args[@]}" >/dev/null 2>&1 || true
      rm -rf "$odir"
      # CONSUME the dedicated reconcile answer (BUG-043): a decision applies ONCE, so
      # a later unrelated answers.json — or a re-run — never re-injects this decision.
      [ -n "$recon_ans" ] && rm -f "$MISSION_DIR/reconcile-answer.txt"
      # Drive + fold; the DRIVE's success/failure is the heal signal (BUG-052).
      reconcile_drive_and_fold; return $?
    fi
    prior_no_file=no-file
    rm -rf "$odir"
  done
  # The author produced nothing across all tries — leave a placeholder PRD so the
  # self-heal still has SOMETHING auditable, then dispatch it (never silently drop).
  local fb; fb="$MISSION_DIR/reconcile-bug-fallback.md"
  {
    printf '# Mission: reconcile failure merging %s into the branch\n' "$BASE"
    printf '**Type:** bug\n'
    printf '**Conflict/failure summary:** %s\n' "$summary"
    printf '**Affected files / tests:** see the summary above.\n'
    printf '**Root cause:** the base moved ahead and the merged state is not green; the author worker could not characterise it.\n'
    printf '**Intended fix:** inspect the conflict/failing suite above and reconcile this branch with the updated base.\n'
  } >"$fb"
  LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" LCARS_WORKER_BIN="$engine" \
    bash "$LOG_SCRIPT" --parent "$MISSION_ID" --prd "$fb" >/dev/null 2>&1 || true
  # CONSUME the dedicated reconcile answer (BUG-043) — a heal was dispatched.
  [ -n "$recon_ans" ] && rm -f "$MISSION_DIR/reconcile-answer.txt"
  # Drive + fold; the DRIVE's success/failure is the heal signal (BUG-052).
  reconcile_drive_and_fold; return $?
}

# BUG-052 — drive the just-logged heal bug(s) to their Verify gate, then fold them
# onto the parent branch. The DRIVE'S EXIT CODE is the heal signal: resolve-logs
# `die`s (non-zero) when a heal child ERRORED — its implement hard-failed and it
# could not be driven to a usable Verify state (WAVE_ERRORED). When that happens
# the heal produced NO healed state, so we return 1 (FAILURE) and the gate escalates
# to an awaiting-human gate INSTEAD of freezing at reconcileStatus=healing. On a
# clean drive (the heal is dispatched + progressing) we fold and return 0 (success
# → the gate halts "reconciling" as before). resolve-logs inherits the parent
# engine via PARENT_ENGINE; complete folds WITHOUT raising resolve-logs' own
# consolidated gate — the S75 verify gate is the single human gate.
reconcile_drive_and_fold() {
  local drive_rc=0
  LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" \
    bash "$RESOLVE_LOGS_SCRIPT" --parent "$MISSION_ID" >/dev/null 2>&1 || drive_rc=$?
  if [ "$drive_rc" -ne 0 ]; then
    # The dispatched heal child could not be driven to a usable healed state — do
    # NOT fold (nothing reached Verify) and signal FAILURE so the gate escalates.
    return 1
  fi
  LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" \
    bash "$RESOLVE_LOGS_SCRIPT" complete --parent "$MISSION_ID" >/dev/null 2>&1 || true
  return 0
}

# BUG-045: DETERMINISTIC design-question authoring. The harness — not the author's
# upfront guess — has decided this conflict is genuinely unresolvable (a dispatched
# heal round could not drive the combined state to green). Re-invoke the reconcile-
# author with a FORCE-DESIGN-QUESTION instruction so it frames the persistent
# failure as ONE experience-framed question for the captain. Echoes the question.
# If the author yields nothing, fall back to a harness-composed, player-facing
# question derived from the mission goal (over-asking the captain beats grinding
# heal rounds silently — they can always reply "just retry").
reconcile_author_design_question() { # failure-summary  affected-block
  local summary="$1" affected="$2"
  local engine; engine="$(json_str "$STATE" workerBin)"
  [ -n "$engine" ] || engine="$WORKER_BIN"
  local sumfile; sumfile="$MISSION_DIR/reconcile-failure.txt"
  printf '%s\n' "$summary" >"$sumfile"
  # FORCE-DESIGN-QUESTION: the marker the worker keys on; the prose tells the author
  # the heal already failed, so this is no longer a "do I heal or ask?" judgement —
  # it MUST emit design-question.txt and author NO bug PRDs.
  local extra="## FORCE-DESIGN-QUESTION — the heal already FAILED; ask the captain
A prior self-heal pass already tried to reconcile this conflict and could NOT drive
the merged state to green: the two sides are competing for the SAME piece of the
player's experience and cannot both hold. This is no longer a judgement call. Do
NOT author any bug PRD. You MUST write a SINGLE design-question.txt containing ONE
concise, experience-framed question (what the player sees / where it sits / how it
behaves), in plain language with 2–3 concrete arrangement options, naming NO code
(no file names, function names, test ids, or 'refactor'). Describe the observable
collision, not its source.

## The persistent merge-failure summary
$affected

The deterministic failure summary is at:
- $sumfile

## The two intents in collision
- This mission's goal/PRD: $MISSION_DIR/prd.md
- What changed on the base branch is quoted in the summary above."

  local odir tries=0 q=""
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    odir="$(mktemp -d)"
    LCARS_WORKER_BIN="$engine" \
      spawn_worker reconcile-author "$STAGES_DIR/reconcile-author.md" repo-read "$odir" "$extra"
    if [ -s "$odir/design-question.txt" ]; then
      q="$(cat "$odir/design-question.txt")"
      rm -rf "$odir"
      break
    fi
    rm -rf "$odir"
  done

  if [ -z "$q" ]; then
    # Harness fallback — a player-facing question framed from the mission goal,
    # carrying NO code identifiers. The captain can always answer "just retry".
    local goal; goal="$(json_str "$STATE" title)"
    [ -f "$MISSION_DIR/prd.md" ] && { local g2; g2="$(sed -n 's/^\*\*Goal:\*\*[[:space:]]*//p' "$MISSION_DIR/prd.md" | head -1)"; [ -n "$g2" ] && goal="$g2"; }
    q="This mission (${goal:-this change}) and a change already on the branch are competing for the same part of the experience, and the harness could not make both work at once. Which should the player get — keep this mission's behaviour, keep the existing one, or some blend of the two? (Reply with the arrangement you want, or say 'just retry' to attempt the merge again.)"
  fi
  printf '%s' "$q"
}

# Escalate to the human after K rounds still red. Never opens a PR.
# $2 = "design" marks this as a reconcile DESIGN-QUESTION gate (BUG-043/055): it
# drops a dedicated marker file so `lcars respond` can tell this gate apart from a
# generic awaiting-human gate — answering it then writes a DEDICATED reconcile
# answer and RESETS the round budget, rather than reusing the generic answers.json.
reconcile_escalate() { # diagnosis-text  [design]
  local diag="$1" kind="${2:-}"
  state_set_str reconcileStatus "escalated"
  if [ "$kind" = "design" ]; then
    printf '%s\n' "$diag" >"$MISSION_DIR/reconcile-design-question.txt"
  fi
  local qf; qf="$(mktemp)"
  printf 'Reconcile with %s failed after %s round(s). Diagnosis:\n%s\n' \
    "$BASE" "$RECONCILE_MAX" "$diag" >"$qf"
  write_pending "$qf" "verify"
  local first; first="$(grep -ve '^[[:space:]]*$' "$qf" | head -1)"
  state_set_raw awaitingHuman true
  state_set_str pendingQuestion "$first"
  rm -f "$qf"
  gh_relabel "lcars:verify lcars:awaiting-human" ""
  emit_event reconcile_escalated verify "reconcile exhausted ${RECONCILE_MAX} round(s) — escalated to the human"
  notify_gate awaiting-human "Reconcile with $BASE failed after $RECONCILE_MAX rounds — needs your call"
  printf 'RECONCILE: escalated — %s rounds exhausted; awaiting human.\n' "$RECONCILE_MAX"
}

# S97 — did the reconcile RETEST go red because the RUNNER could not START, rather
# than because of a real logical conflict? A reconcile merge worktree that is not
# provisioned (no node_modules / no worktreeSetupCommand, a missing testCommand
# binary, `cd: <pkg>: No such file or directory`) makes EVERY ticket suite error at
# STARTUP — which the reconcile would otherwise mis-read as an ALL-SUITES-RED
# logical conflict and chase with a phantom self-heal bug (the S97 demo bug). This
# is a PURE, offline verdict built on the SAME env-failure detector the Implement /
# full-suite gates use (red_gate_env_failure), so an unprovisioned retest is NEVER
# chased as a code fault. $1 is the retest CAPTURE dir (the reconcile writes one
# <id>.log per failing suite there) OR a single log file OR raw text (test
# convenience). Returns 0 (env-blocked: the runner could not start) or 1 (a genuine
# red the self-heal path may act on).
reconcile_retest_env_blocked() { # capture-dir-or-log-or-text → 0 if env-blocked
  local p="${1:-}" out=""
  if [ -d "$p" ]; then
    out="$(cat "$p"/*.log 2>/dev/null)"
  elif [ -f "$p" ]; then
    out="$(cat "$p" 2>/dev/null)"
  else
    out="$p"
  fi
  red_gate_env_failure "$out"
}

# S97 — the reconcile merge was CLEAN but the RETEST could not RUN (the merge
# worktree was not provisioned). This is NOT a logical merge conflict, so we must
# NOT self-heal and must NOT author a phantom reconcile-bug PRD. STOP at an
# actionable awaiting-human gate that names worktreeSetupCommand, preserving the raw
# captured output so the captain sees exactly why the runner could not start. Mirrors
# reconcile_escalate's gate wiring, but with a DISTINCT status (env-blocked, so a
# re-run after the captain fixes the config re-attempts rather than being suppressed
# by the escalated-idempotency guard) and a DISTINCT event (reconcile_env_blocked).
reconcile_retest_env_escalate() { # failed-ids  captured-output
  local ids="$1" cap_out="$2"
  state_set_str reconcileStatus "env-blocked"
  local note="Reconcile with $BASE merged CLEANLY, but the re-test could not RUN — the reconcile merge worktree was not provisioned (no node_modules / the testCommand binary was not found), so the mission's ticket suite(s) errored at startup. This is NOT a code conflict. Set \`worktreeSetupCommand\` in .git/lcars/config.json (see \`lcars update\`) so the retest environment matches the build, then re-run \`lcars approve\` / \`lcars run\`."
  local qf; qf="$(mktemp)"
  {
    printf '%s\n\nSuite(s) that could not run: %s\n' "$note" "${ids:-all}"
    if [ -n "$cap_out" ]; then
      printf '\nCaptured retest output (raw):\n%s\n' "$cap_out"
    fi
  } >"$qf"
  write_pending "$qf" "verify"
  state_set_str reconcileDiagnosis "$note"
  state_set_raw awaitingHuman true
  state_set_str pendingQuestion "$note"
  rm -f "$qf"
  gh_relabel "lcars:verify lcars:awaiting-human" ""
  emit_event reconcile_env_blocked verify "reconcile merged $BASE cleanly but the retest could not run — the merge worktree was not provisioned; set worktreeSetupCommand (NOT a code conflict)"
  notify_gate awaiting-human "$note"
  printf 'RECONCILE: env-blocked — merged %s cleanly but the retest could not run (worktree not provisioned); set worktreeSetupCommand and re-run.\n' "$BASE"
}

# The reconcile gate. Echoes a RECONCILE: line and returns:
#   0  ("RECONCILE: ok")          → not ahead, or clean+green → caller proceeds to
#                                    open the PR. The merge (if any) is already on
#                                    the live branch.
#   10 ("RECONCILE: reconciling") → red → self-heal dispatched, halt this pass.
#   20 ("RECONCILE: escalated")   → K rounds exhausted → awaiting-human, no PR.
reconcile_gate() {
  local BASE BRANCH
  BRANCH="$(json_str "$STATE" branch)"
  BASE="$(json_str "$STATE" base)"; BASE="${BASE:-main}"

  # Idempotency: once this reconcile has ESCALATED (awaiting the captain's call —
  # an exhausted heal, a design trade-off, or a worktree-cut failure), a re-run of
  # the gate must NOT re-escalate or re-notify. The mission stays parked at verify
  # awaiting-human until `lcars respond` clears the gate; only then does a fresh
  # pass re-enter the heal. This keeps "exactly one gate notification" true under
  # the BUG-045 earlier (post-heal) design-question escalation. (BUG-041/045)
  if [ "$(json_str "$STATE" reconcileStatus)" = "escalated" ] \
     && [ "$(json_raw "$STATE" awaitingHuman)" = "true" ]; then
    echo "RECONCILE: escalated — awaiting the captain's answer; not re-asking."
    return 20
  fi

  # No branch → nothing to reconcile; let the open-PR path handle the no-branch die.
  [ -n "$BRANCH" ] || { echo "RECONCILE: ok — no branch on file"; return 0; }
  "$GIT_BIN" show-ref --verify --quiet "refs/heads/$BRANCH" \
    || { echo "RECONCILE: ok — branch not present locally"; return 0; }

  # BUG-077: don't diverge on re-entry. A reconcile killed/parked and retried leaves
  # the LOCAL mission branch at the dead attempt's merge commit; merging main onto
  # THAT makes the local reconciled tip DIVERGE from the last-pushed remote PR head,
  # so the eventual push is rejected non-fast-forward and approve gets stuck. When a
  # REMOTE PR branch already exists, reset the local branch to the remote PR head
  # BEFORE merging main again — so a retry merges from the SAME base the remote has
  # and cannot diverge. Guard: only on a RE-ENTRY for a mission that ALREADY has an
  # open PR (prUrl recorded) — the `lcars approve` merge-gate retry context where
  # BUG-077 occurs. The pre-PR drive_verify path (no prUrl) is unchanged: there the
  # branch's local-only commits (a fresh merge / textual-conflict resolution that
  # hasn't been pushed yet) are the authoritative work and must NOT be discarded.
  local pr_for_reset; pr_for_reset="$(json_str "$STATE" prUrl)"
  case "$pr_for_reset" in http*|*/pull/*) : ;; *) pr_for_reset="" ;; esac
  if [ -n "$pr_for_reset" ] \
     && "$GIT_BIN" fetch origin "$BRANCH" --quiet 2>/dev/null \
     && "$GIT_BIN" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    local local_tip remote_tip
    local_tip="$("$GIT_BIN" rev-parse "$BRANCH" 2>/dev/null)"
    remote_tip="$("$GIT_BIN" rev-parse "origin/$BRANCH" 2>/dev/null)"
    if [ -n "$remote_tip" ] && [ "$local_tip" != "$remote_tip" ]; then
      # If the live tree is checked out ON the branch, detach it first so the ref
      # can be moved (mirrors the worktree-cut detach below).
      if [ "$( cd "$REPO_ROOT" && "$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null )" = "$BRANCH" ]; then
        ( cd "$REPO_ROOT" && "$GIT_BIN" checkout --detach --quiet ) >/dev/null 2>&1 || :
      fi
      if "$GIT_BIN" branch -f "$BRANCH" "origin/$BRANCH" >/dev/null 2>&1; then
        emit_event reconcile_reset verify "re-entry: reset local '$BRANCH' to the remote PR head ($(printf '%s' "$remote_tip" | cut -c1-7)) before re-merging — avoids divergence"
      fi
    fi
  fi

  # (a) main-ahead check. Best-effort; any unresolvable/non-numeric → not-ahead.
  local base_ref ahead
  base_ref="$(reconcile_base_ref)"
  if [ -z "$base_ref" ]; then
    echo "RECONCILE: ok — base '$BASE' unresolvable; proceeding (not ahead)"
    return 0
  fi
  ahead="$("$GIT_BIN" rev-list --count "$BRANCH..$base_ref" 2>/dev/null)"
  case "$ahead" in
    ''|*[!0-9]*) echo "RECONCILE: ok — ahead count indeterminate; proceeding (not ahead)"; return 0 ;;
    0)           echo "RECONCILE: ok — base '$BASE' not ahead of '$BRANCH'; proceeding"; return 0 ;;
  esac

  # Base is ahead → reconcile. Bump the round counter (persists across passes).
  local round; round="$(json_raw "$STATE" reconcileRound)"
  case "$round" in ''|*[!0-9]*) round=0 ;; esac
  round=$((round + 1))
  state_set_raw reconcileRound "$round"
  state_set_str reconcileStatus "merging"
  emit_event reconcile_start verify "base '$BASE' is $ahead commit(s) ahead — reconciling (round $round)" \
    "round=$round" "ahead=$ahead"

  # K exhausted? If this pass would be round > K, escalate instead of re-attempting.
  if [ "$round" -gt "$RECONCILE_MAX" ]; then
    local prev; prev="$(json_str "$STATE" reconcileDiagnosis)"
    [ -n "$prev" ] || prev="the merged state was not green against '$BASE'."
    reconcile_escalate "$prev"
    return 20
  fi

  # (b) MERGE (not rebase) in an isolated worktree ATTACHED to the mission branch.
  # BUG-054: a reconcile pass run while $REPO_ROOT is ON the mission branch (the
  # normal post-Implement/post-heal state — the heal's cherry-pick leaves it there)
  # cannot cut an ATTACHED worktree on that branch ("already checked out at …").
  # Detach the main tree off the branch first so the cut succeeds; the heal re-checks
  # the branch out in $REPO_ROOT as it needs it, and the captain's tree ends on the
  # branch as usual.
  if [ "$( cd "$REPO_ROOT" && "$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null )" = "$BRANCH" ]; then
    ( cd "$REPO_ROOT" && "$GIT_BIN" checkout --detach --quiet ) >/dev/null 2>&1 || :
  fi
  local wt; wt="$(mktemp -d "$MISSION_DIR/reconcile.XXXXXX")"; rm -rf "$wt"
  if ! "$GIT_BIN" worktree add -q "$wt" "$BRANCH" >/dev/null 2>&1; then
    # BUG-038: do NOT silently "proceed". A failed worktree cut means we could not
    # reconcile at all — returning 0 here would let the caller MERGE an un-reconciled
    # branch (conflict → wrong). First try to RECOVER (a stale/abandoned worktree is
    # the common cause), then retry ONCE; only if it still fails do we escalate with
    # a clear, actionable message. Never report success when no reconcile happened.
    rm -rf "$wt"
    "$GIT_BIN" worktree prune >/dev/null 2>&1 || :
    wt="$(mktemp -d "$MISSION_DIR/reconcile.XXXXXX")"; rm -rf "$wt"
    if ! "$GIT_BIN" worktree add -q "$wt" "$BRANCH" >/dev/null 2>&1; then
      rm -rf "$wt"
      # Roll the round back — this pass did nothing — so the round counter reflects
      # only real reconcile attempts, then escalate honestly (awaiting-human, no PR).
      round=$((round - 1))
      if [ "$round" -le 0 ]; then state_del reconcileRound; else state_set_raw reconcileRound "$round"; fi
      local wt_diag="Can't reconcile with '$BASE' — the mission branch '$BRANCH' is checked out in another worktree, or a stale worktree is blocking an isolated cut. Free it (\`git worktree list\` then \`git worktree remove\`/\`git worktree prune\`) and re-run."
      reconcile_escalate "$wt_diag"
      echo "RECONCILE: cannot reconcile — the mission branch is checked out in another worktree or a stale worktree exists; free it and re-run."
      return 20
    fi
  fi
  # S97 — ENV PARITY: provision the reconcile merge worktree EXACTLY as the Implement
  # gates provision theirs (make_ticket_worktree / the post-commit gate both call
  # provision_worktree right after `git worktree add`), so the configured testCommand
  # can RESOLVE (node_modules, package layout, the test binary) when the retest runs.
  # Without this the retest errors at STARTUP and the reconcile mis-reads that as an
  # all-suites-red LOGICAL conflict, chasing a phantom self-heal bug (the S97 demo
  # bug). REUSES the shared primitive — no forked/weaker setup. Best-effort: a failure
  # drops a breadcrumb and is CAUGHT by the S97 env-blocked routing below (it is never
  # chased as a code conflict). NEVER clobbers the captain's configured command.
  provision_worktree "$wt" || :
  # Record the branch's PRE-MERGE tip so a RED reconcile can UNDO the merge: the
  # merge commits onto the live branch ref, and we must NOT leave a broken merge on
  # the branch (it would read as "not ahead" next pass and ship a stale-and-broken
  # tree). Only a GREEN reconcile keeps the merge. The bug-children's fixes land on
  # the branch via the Mission Log machinery (from $REPO_ROOT), so on the next pass
  # the still-behind branch re-merges WITH the fixes present.
  local pre_merge; pre_merge="$( cd "$wt" && "$GIT_BIN" rev-parse HEAD 2>/dev/null )"
  # Clean up this gate's OWN worktree path on every exit (never a global prune).
  # On a RED outcome the caller resets the branch to $pre_merge BEFORE cleanup.
  reconcile_cleanup() { "$GIT_BIN" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; }
  reconcile_undo_merge() {
    [ -n "$pre_merge" ] || return 0
    ( cd "$wt" && "$GIT_BIN" merge --abort >/dev/null 2>&1; "$GIT_BIN" reset -q --hard "$pre_merge" >/dev/null 2>&1 ) || :
  }

  local merge_rc=0 conflicted=""
  ( cd "$wt" && "$GIT_BIN" merge --no-edit "$base_ref" ) >/dev/null 2>&1 || merge_rc=$?
  if [ "$merge_rc" -ne 0 ]; then
    conflicted="$( cd "$wt" && "$GIT_BIN" diff --name-only --diff-filter=U 2>/dev/null )"
    emit_event reconcile_conflict verify "textual merge conflict in: $(printf '%s' "$conflicted" | tr '\n' ' ')"
  fi

  # The base-change intent — what moved on main since this branch was cut.
  local base_log; base_log="$("$GIT_BIN" log --oneline "$BRANCH..$base_ref" 2>/dev/null | head -40)"

  # (c) Decide: textual conflict = red WITHOUT running tests. Otherwise scoped
  # re-test (ALWAYS, even on a clean merge — S73, to catch silent logical conflicts).
  local cmd; cmd="$(resolve_test_cmd)"
  local ordered; ordered="$(reconcile_ordered_tickets)"
  local failure_summary="" red=0

  if [ -n "$conflicted" ]; then
    red=1
    failure_summary="MERGING $BASE into the mission branch produced a TEXTUAL conflict.

Conflicted file(s):
$conflicted

Conflict hunk(s):"
    local cf
    while IFS= read -r cf; do
      [ -n "$cf" ] || continue
      failure_summary="$failure_summary

--- $cf ---
$(sed -n '/^<<<<<<< /,/^>>>>>>> /p' "$wt/$cf" 2>/dev/null | head -60)"
    done <<EOF
$conflicted
EOF
  else
    state_set_str reconcileStatus "retesting"
    emit_event reconcile_retest verify "clean merge — re-testing $ordered against the merged state"
    if [ -n "$cmd" ] && [ -n "$ordered" ]; then
      local cap; cap="$(mktemp -d)"
      if ! RETEST_CAPTURE="$cap" retest_ticket_suites "$wt" "$cmd" $ordered; then
        red=1
        # S97 — ENV-FAILURE ROUTING: the retest went RED — but did the runner actually
        # RUN? An unprovisioned merge worktree (no node_modules, a missing testCommand
        # binary, `cd: <pkg>: No such file or directory`, `vitest: not found`) makes
        # EVERY suite error at STARTUP. That is NOT a logical merge conflict — the merge
        # was clean; only the retest ENVIRONMENT is broken. Reading it as a code
        # conflict auto-files a phantom self-heal bug (the S97 demo bug). Classify the
        # captured retest output through the SAME env detector the Implement/full-suite
        # gates use; on an env-failure, STOP at an actionable awaiting-human gate
        # (env-blocked) — undo the un-verifiable merge so a re-run re-tests, preserve
        # the raw output, and NEVER reach the self-heal author. Only a GENUINE red (real
        # assertion failures after a provisioned run) falls through to self-heal below.
        if reconcile_retest_env_blocked "$cap"; then
          local envcap; envcap="$(cat "$cap"/*.log 2>/dev/null)"
          local envids="$RETEST_FAILED"
          rm -rf "$cap"
          reconcile_undo_merge
          reconcile_cleanup
          reconcile_retest_env_escalate "$envids" "$envcap"
          return 20
        fi
        failure_summary="MERGING $BASE into the mission branch merged CLEANLY, but re-running the mission's own ticket suite(s) against the combined state went RED (a silent logical conflict).

Failing ticket suite(s): $RETEST_FAILED

Captured output:"
        local fid
        for fid in $RETEST_FAILED; do
          failure_summary="$failure_summary

--- $fid ---
$(head -80 "$cap/$fid.log" 2>/dev/null)"
        done
      fi
      rm -rf "$cap"
    fi
  fi

  # Append the two intents to every summary.
  local goal=""; [ -f "$MISSION_DIR/prd.md" ] && goal="$(sed -n 's/^\*\*Goal:\*\*[[:space:]]*//p' "$MISSION_DIR/prd.md" | head -1)"
  failure_summary="$failure_summary

THIS MISSION'S GOAL: ${goal:-$(json_str "$STATE" title)}
WHAT CHANGED ON $BASE (oldest→newest):
${base_log:-(no log available)}"

  # BUG-056 — CONVERGE a TEXTUAL conflict by KEEPING a resolved merge. Before
  # undoing the merge and re-healing on the un-merged branch (which re-conflicts on
  # the next fresh merge forever), try to RESOLVE the markers IN this merge worktree
  # and KEEP the merge. On success the branch ref advances to the merged+resolved
  # commit → it now CONTAINS base → the next pass reads "not behind" → green. Only
  # the textual-conflict path takes this; the clean-merge logical-conflict path
  # ($conflicted empty) is untouched and still self-heals exactly as before.
  if [ -n "$conflicted" ] && [ "$red" -eq 1 ]; then
    if reconcile_resolve_in_worktree "$wt" "$base_ref" "$failure_summary" \
         "Conflicted/affected: $conflicted" "$cmd" $ordered; then
      red=0   # converged → fall through to the shared GREEN exit (keeps the merge)
    fi
  fi

  if [ "$red" -eq 0 ]; then
    # Clean (or conflict-free) AND green: the worktree committed the merge ON the
    # branch, so the live branch ref already advanced — just remove the worktree.
    reconcile_cleanup
    state_del reconcileRound
    state_del reconcileDiagnosis

    # BUG-067 — a self-heal that converges green AFTER a PR is open must NOT
    # auto-merge. The captain has not seen the reconciled tree; blindly running
    # `gh pr merge` (the old approve behaviour) gives them no sign-off and, when a
    # push silently fails, reverts the mission to verify with no surfaced reason
    # (BUG-066). So when a PR already exists (the `lcars approve` merge-gate flow),
    # we STOP here, persist a human-readable awaiting-reapprove gate keyed off the
    # reconciled tip, and let the captain REAPPROVE the merge once they have looked.
    # The no-PR path (drive_verify, before the PR is opened) is unchanged: it
    # clears the status and returns 0 so the driver proceeds to OPEN the PR — that
    # PR-open IS the human surface there.
    local pr_open; pr_open="$(json_str "$STATE" prUrl)"
    case "$pr_open" in
      http*|*/pull/*)
        local merge_sha total
        merge_sha="$("$GIT_BIN" rev-parse "$BRANCH" 2>/dev/null)"
        total="$(printf '%s\n' "$ordered" | tr ' ' '\n' | grep -c .)"
        [ -n "$total" ] && [ "$total" != 0 ] || total=1
        local short; short="$(printf '%s' "$merge_sha" | cut -c1-7)"
        local note="Reconciled $BASE into the branch ($short) and re-tested green ($total/$total). Reapprove to merge."
        state_set_str reconcileStatus "awaiting-reapprove"
        state_set_str reconcileNote "$note"
        state_set_str reconcileMergeSha "$merge_sha"
        state_set_raw awaitingHuman true
        state_set_str pendingQuestion "$note"
        local qf; qf="$(mktemp)"
        printf '%s\nReapprove to merge the reconciled branch, or send it back.\n' "$note" >"$qf"
        write_pending "$qf" "verify"
        rm -f "$qf"
        gh_relabel "lcars:verify lcars:awaiting-human" ""
        emit_event reconcile_reapprove verify "merged $BASE and re-test is green ($total/$total) — awaiting your reapprove before merging"
        notify_gate awaiting-human "$note"
        echo "RECONCILE: awaiting-reapprove — merged $BASE; re-test green ($total/$total); reapprove to merge ($short)."
        return 30 ;;
    esac

    state_del reconcileStatus
    emit_event reconcile_green verify "merged $BASE and re-test is green — proceeding to open the PR"
    echo "RECONCILE: ok — merged $BASE; re-test green; proceeding"
    return 0
  fi

  # RED. UNDO the broken merge on the branch (never leave a stale-and-broken merge
  # that reads as "not ahead" next pass), persist the diagnosis for a later
  # escalation.
  reconcile_undo_merge
  # BUG-053: free THIS gate's attached worktree NOW — BEFORE any heal/author work.
  # reconcile_undo_merge above resets the branch via $wt (so it must run while $wt
  # exists), but the self-heal child cherry-picks its green commit by checking out
  # $BRANCH in $REPO_ROOT; if the reconcile worktree still has $BRANCH checked out,
  # that checkout fails ("already checked out") and the heal can never land. Cleaning
  # up here frees $BRANCH so the heal succeeds. The later cleanup calls are now
  # redundant and have been removed.
  reconcile_cleanup
  state_set_str reconcileDiagnosis "$failure_summary"
  local affected="Conflicted/affected: ${conflicted:-$RETEST_FAILED}"

  # BUG-045 — DETERMINISTIC post-heal design-question escalation (the PRIMARY fix).
  # If a self-heal round ALREADY ran on a prior pass (round > 1) and the combined
  # state is STILL red, the dispatched heal could not drive the conflict to green:
  # the two sides are competing for the same piece of the experience and cannot
  # both hold. Do NOT grind another heal round to the cap, and do NOT escalate with
  # only a generic diagnosis — re-author the persistent failure as an experience-
  # framed DESIGN QUESTION and escalate with it RELIABLY, regardless of whether the
  # author guessed "trade-off" upfront. The captain answers (or says "just retry");
  # a later pass (after `lcars respond`) injects their decision into the heal.
  # Skip this ONLY when the captain has ALREADY answered THIS reconcile's design
  # question — i.e. a DEDICATED reconcile answer is in hand (BUG-043). The generic
  # answers.json must NEVER suppress this escalation: it is written for ANY
  # awaiting-human gate and could be a stale, unrelated decision.
  if [ "$round" -gt 1 ] && [ ! -s "$MISSION_DIR/reconcile-answer.txt" ]; then
    emit_event reconcile_red verify "merged $BASE but a prior heal could not reach green — re-framing as a design question (round $round)"
    local dq; dq="$(reconcile_author_design_question "$failure_summary" "$affected")"
    reconcile_escalate "$dq" design
    return 20
  fi

  # First RED round: author + dispatch the self-heal, clean up the worktree, and
  # halt "reconciling" for THIS pass. The next pass re-merges the (still-behind)
  # branch with the just-landed bug fixes present — and if it is STILL red, the
  # deterministic BUG-045 path above escalates a design question.
  emit_event reconcile_red verify "merged $BASE but the combined state is not green — self-healing (round $round)"
  local heal_rc=0
  reconcile_author_and_dispatch "$failure_summary" "$affected" || heal_rc=$?

  # BUG-042: the author judged this an UNRESOLVABLE design trade-off UPFRONT and
  # posed an experience-framed question rather than a self-heal. There is nothing to
  # iterate on — escalate NOW with the player-facing question so the captain decides;
  # the next pass (after `lcars respond`) injects their answer into the heal.
  if [ -n "$RECONCILE_DESIGN_QUESTION" ]; then
    reconcile_escalate "$RECONCILE_DESIGN_QUESTION" design
    return 20
  fi

  # BUG-052: the dispatched HEAL DRIVE itself FAILED — the heal child errored and
  # could not be driven to a usable healed state (e.g. its implement hard-failed).
  # Do NOT set reconcileStatus=healing + return 10: that would leave the parent
  # FROZEN (stale healing, nothing running, no gate, Merge suppressed by the
  # BUG-035/039 lock with no escape). Instead escalate cleanly to an awaiting-human
  # gate so the board's gate rendering clears the lock and the captain gets an
  # action. The author already persisted the diagnosis; surface it.
  if [ "$heal_rc" -ne 0 ]; then
    local hd; hd="$(json_str "$STATE" reconcileDiagnosis)"
    [ -n "$hd" ] || hd="$failure_summary"
    hd="The self-heal for this reconcile could not be completed — the dispatched fix errored before reaching a usable state. $hd"
    emit_event reconcile_red verify "the dispatched self-heal failed to reach a usable state — escalating to the human (round $round)"
    reconcile_escalate "$hd"
    return 20
  fi

  state_set_str reconcileStatus "healing"
  echo "RECONCILE: reconciling — merged $BASE; combined state not green; self-heal dispatched (round $round/$RECONCILE_MAX)"
  return 10
}

# The `reconcile` subcommand: drive the gate once (used directly by drive_verify
# in-process AND exposed for tests). Mirrors cmd_open_pr's locate/require.
cmd_reconcile() {
  locate_mission "$MISSION_ID"
  require_stage verify
  resolve_worker
  local rc=0
  reconcile_gate || rc=$?
  exit "$rc"
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
# The role→toolset table (and the CLI flag names) now live in the cold-worker
# CLI adapter (worker-adapter.sh), keyed by cli id, so this driver knows neither
# the flags nor the tool NAMES. Read-only-on-the-repo for Validate/Plan/Review/
# question-gen; +web for the research agents; +write+shell for the Implementer.
# (All roles may write into their own scratch output dir — that is their answer
# channel, not the repo.) The adapter `spawn` is reached via worker_spawn() below.

# --- resolve WHICH cli to run as the cold worker, and with which model -------
# Resolution is CLI-AGNOSTIC and so lives HERE, not in the adapter: the adapter
# owns cli-SPECIFIC flag emission, run.sh owns host detection + precedence.
#
#   bin precedence  : $LCARS_WORKER_BIN  >  config.json workerBin
#                     >  host-CLI auto-detect (env marker) >  claude (default)
#   model precedence: $LCARS_WORKER_MODEL > config.json workerModel > unset
#
# Host detection keys off the per-process env var a spawned shell inherits from
# the launching CLI: CLAUDECODE=1 ⇒ claude. The real GitHub Copilot CLI (v1.0.60)
# sets COPILOT_RUN_APP=1 + COPILOT_CLI_BINARY_VERSION (+ COPILOT_LOADER_PID) and
# does NOT set COPILOT_CLI, so we treat COPILOT_RUN_APP=1 OR a non-empty
# COPILOT_CLI_BINARY_VERSION as the copilot marker (resilient to either var
# changing across versions). `~/.copilot` existing is NOT a launch signal and is
# never consulted.
# If no marker is present we do NOT guess: we fall back to claude (the historical
# default) and note it via the `default` source.
#
# config.json's workerBin/workerModel are OPTIONAL sibling string fields (absent
# = unset); read with the same jq-free json_str the rest of the script uses, only
# when $LCARS_CFG points at an existing file.

# Detect the host CLI from its per-process env marker. Prints the cli id, or
# nothing if no reliable marker is set (caller then falls back, never guesses).
detect_host_cli() {
  if [ "${CLAUDECODE:-}" = "1" ]; then printf 'claude'; return 0; fi
  if [ "${COPILOT_RUN_APP:-}" = "1" ] || [ -n "${COPILOT_CLI_BINARY_VERSION:-}" ]; then
    printf 'copilot'; return 0
  fi
  return 0   # no marker — caller degrades to the claude default + LOGs it.
}

# Resolve WORKER_BIN + WORKER_BIN_SRC by the precedence above.
resolve_worker_bin() {
  if [ -n "${LCARS_WORKER_BIN:-}" ]; then
    WORKER_BIN="$LCARS_WORKER_BIN"; WORKER_BIN_SRC="env"; return 0
  fi
  local cfgbin=""
  [ -n "${LCARS_CFG:-}" ] && [ -f "${LCARS_CFG:-}" ] && cfgbin="$(json_str "$LCARS_CFG" workerBin)"
  if [ -n "$cfgbin" ]; then
    WORKER_BIN="$cfgbin"; WORKER_BIN_SRC="config"; return 0
  fi
  local detected; detected="$(detect_host_cli)"
  if [ -n "$detected" ]; then
    WORKER_BIN="$detected"; WORKER_BIN_SRC="detected"; return 0
  fi
  # No env, no config, no host marker — never guess the CLI.
  printf 'lcars run: no host-CLI marker — defaulting to claude\n' >&2
  WORKER_BIN="claude"; WORKER_BIN_SRC="default"
}

# Resolve WORKER_MODEL + WORKER_MODEL_SRC by the precedence above. Unset model
# (empty WORKER_MODEL) ⇒ the adapter emits NO --model flag (session-18 argv).
resolve_worker_model() {
  if [ -n "${LCARS_WORKER_MODEL:-}" ]; then
    WORKER_MODEL="$LCARS_WORKER_MODEL"; WORKER_MODEL_SRC="env"; return 0
  fi
  local cfgmodel=""
  [ -n "${LCARS_CFG:-}" ] && [ -f "${LCARS_CFG:-}" ] && cfgmodel="$(json_str "$LCARS_CFG" workerModel)"
  if [ -n "$cfgmodel" ]; then
    WORKER_MODEL="$cfgmodel"; WORKER_MODEL_SRC="config"; return 0
  fi
  WORKER_MODEL=""; WORKER_MODEL_SRC="unset"
}

# === Per-stage model selection (session 58) =================================
# Today resolve_worker_model picks ONE global model for every headless stage.
# This seam lets a declarative source assign a DIFFERENT model per stage, while
# emitting BYTE-IDENTICAL argv to the legacy path whenever no per-stage source is
# present. It is a SELECTION change only — gate mechanics, prompts, the driver's
# stage logic, event format and the adapter's argv ORDER are untouched.

# Map a spawn ROLE (the env-role the worker sees) → its STAGE KEY. One place.
# A role with no stage key (none today) falls through to the global/unset path.
# `context-pack` maps to `infra` but is NEVER escalated (see resolve_stage_model).
stage_key_for_role() { # role → stage key (stdout; empty if none)
  case "$1" in
    research-questions|research-agent|research-grounding)  printf 'research' ;;
    validate)                                     printf 'validate' ;;
    plan)                                         printf 'plan' ;;
    plan-review)                                  printf 'planReview' ;;
    implement-test-writer|implement-implementer)  printf 'implement' ;;
    context-pack)                                 printf 'infra' ;;
  esac
}

# Translate a logical TIER ("sonnet"/"opus") → the ACTIVE worker CLI's flag string.
# Defaults below; config.json `modelAliases.<cli>.<tier>` overrides per (cli,tier).
# A tier with no mapping (and no override) yields empty — caller treats empty as
# "no flag", i.e. the legacy no-`--model` argv. The active CLI is the same id
# worker_spawn computes (LCARS_WORKER_CLI or basename WORKER_BIN).
alias_for_tier() { # cli tier → flag string (stdout; may be empty)
  local cli="$1" tier="$2" override=""
  [ -n "${LCARS_CFG:-}" ] && [ -f "${LCARS_CFG:-}" ] \
    && override="$(json_scoped_str "$LCARS_CFG" "modelAliases.$cli.$tier")"
  if [ -n "$override" ]; then printf '%s' "$override"; return 0; fi
  case "$cli" in
    claude)
      case "$tier" in sonnet) printf 'sonnet' ;; opus) printf 'opus' ;; esac ;;
    copilot)
      # S78 — copilot is OPUS-SAFE BY DEFAULT: BOTH the sonnet AND the opus tier
      # resolve to `claude-opus-4.8`, so a Copilot mission runs opus on EVERY
      # stage regardless of the estimator's tier. WHY: Copilot's `create` tool
      # cannot overwrite an existing file (or mkdir) on a non-opus tier, so a
      # sonnet-tier Implement stage breaks the run. Pinning opus everywhere keeps
      # Copilot end-to-end-safe. This is the ONE home for the policy. Both tiers
      # stay config-overridable via modelAliases.copilot.<tier> (handled above):
      # a repo that sets modelAliases.copilot.sonnet still wins over this default.
      case "$tier" in sonnet) printf 'claude-opus-4.8' ;; opus) printf 'claude-opus-4.8' ;; esac ;;
  esac
}

# Is STAGE KEY inside the captain override's SCOPE? The two axes:
#   reasoning      = research, validate, plan, planReview
#   implementation = implement, verify
#   all            = every one of the above (whole-way override)
# `infra` (context-pack) is never in any scope — it is never escalated.
stage_in_override_scope() { # key scope → 0 if in scope, 1 otherwise
  local key="$1" scope="$2"
  case "$scope" in
    all)
      case "$key" in
        research|validate|plan|planReview|implement|verify) return 0 ;;
      esac ;;
    reasoning)
      case "$key" in research|validate|plan|planReview) return 0 ;; esac ;;
    implementation)
      case "$key" in implement|verify) return 0 ;; esac ;;
  esac
  return 1
}

# The ACTIVE captain override, as "<scope>:<tier>", or empty when none. The env
# path ($LCARS_MODEL_OVERRIDE) WINS over the persisted state.json modelOverride —
# mirroring the env-over-config rule everywhere else in the resolver. Both store a
# scope + a LOGICAL TIER (sonnet/opus); the caller alias-maps the tier per CLI.
active_model_override() { # → "<scope>:<tier>" or empty
  if [ -n "${LCARS_MODEL_OVERRIDE:-}" ]; then
    printf '%s' "$LCARS_MODEL_OVERRIDE"; return 0
  fi
  # state.json modelOverride: { "scope": "...", "tier": "..." }
  if [ -n "${MISSION_DIR:-}" ] && [ -f "$MISSION_DIR/state.json" ]; then
    local scope tier
    scope="$(json_scoped_str "$MISSION_DIR/state.json" "modelOverride.scope")"
    tier="$(json_scoped_str "$MISSION_DIR/state.json" "modelOverride.tier")"
    if [ -n "$scope" ] && [ -n "$tier" ]; then printf '%s:%s' "$scope" "$tier"; fi
  fi
}

# Resolve the CLI flag string (or empty) for one STAGE KEY. Precedence, high→low:
#   a.  $LCARS_WORKER_MODEL env  — global pin, wins for ALL stages. VERBATIM (it is
#       already a CLI flag string, NOT a tier — do not re-translate it).
#   a2. captain model override — $LCARS_MODEL_OVERRIDE env (wins) OR state.json
#       modelOverride; "<scope>:<tier>". For a stage WITHIN the override's scope,
#       use the override tier (alias-mapped). Stages OUTSIDE the scope fall through
#       to the estimate below. (Session 62.)
#   b.  estimate.json models.<key> — logical tier → alias-mapped per active CLI.
#   c.  config.json stages.<key>.model — logical tier → alias-mapped.
#   d.  config.json workerModel — global, VERBATIM flag (legacy back-compat).
#   e.  nothing ⇒ empty string (caller emits NO --model flag — byte-identical).
# `infra` (context-pack) is a cheap repo-fact pass and is NEVER escalated by the
# estimate/stage map OR the captain override: it short-circuits to the global/
# legacy value (env pin > the global config workerModel > unset) so its argv stays
# exactly as today.
resolve_stage_model() { # stage-key → flag string (stdout; may be empty)
  local key="$1"
  # (a) global env pin — wins for every stage, verbatim.
  if [ -n "${LCARS_WORKER_MODEL:-}" ]; then printf '%s' "$LCARS_WORKER_MODEL"; return 0; fi
  local cli; cli="${LCARS_WORKER_CLI:-$(basename "${WORKER_BIN:-claude}")}"
  if [ "$key" != "infra" ] && [ -n "$key" ]; then
    # (a2) captain model override — only for stages within its scope.
    local ov; ov="$(active_model_override)"
    if [ -n "$ov" ]; then
      local ov_scope="${ov%%:*}" ov_tier="${ov#*:}"
      if stage_in_override_scope "$key" "$ov_scope"; then
        alias_for_tier "$cli" "$ov_tier"; return 0
      fi
    fi
    # (b) estimate.json models.<key>
    local est_tier=""
    [ -n "${MISSION_DIR:-}" ] && [ -f "$MISSION_DIR/estimate.json" ] \
      && est_tier="$(json_scoped_str "$MISSION_DIR/estimate.json" "models.$key")"
    if [ -n "$est_tier" ]; then alias_for_tier "$cli" "$est_tier"; return 0; fi
    # (c) config.json stages.<key>.model
    local cfg_tier=""
    [ -n "${LCARS_CFG:-}" ] && [ -f "${LCARS_CFG:-}" ] \
      && cfg_tier="$(json_scoped_str "$LCARS_CFG" "stages.$key.model")"
    if [ -n "$cfg_tier" ]; then alias_for_tier "$cli" "$cfg_tier"; return 0; fi
  fi
  # (d) config.json workerModel — global, VERBATIM (it is a raw flag today, not a
  # tier — keep it verbatim for back-compat). Applies to infra too.
  local cfg_global=""
  [ -n "${LCARS_CFG:-}" ] && [ -f "${LCARS_CFG:-}" ] \
    && cfg_global="$(json_str "$LCARS_CFG" workerModel)"
  if [ -n "$cfg_global" ]; then printf '%s' "$cfg_global"; return 0; fi
  # (e) nothing.
  printf ''
}

# The `resolve-stage-model <key>` subcommand: a mission-free test surface over
# resolve_stage_model, mirroring cmd_resolve_worker. Resolves the worker bin (to
# fix the active CLI) + $LCARS_CFG; reads estimate.json from --mission's dir when
# given; prints `STAGE-MODEL key=<k> model=<flag|->` so tests assert the resolved
# flag without an LLM or a real spawn. No mission state is required beyond the dir.
cmd_resolve_stage_model() { # key (positional, in $1)
  local key="$1" gitdir
  gitdir="$("$GIT_BIN" rev-parse --git-common-dir 2>/dev/null)" || gitdir=""
  if [ -n "$gitdir" ]; then
    case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
    LCARS_CFG="$gitdir/lcars/config.json"
    [ -n "${MISSION_ID:-}" ] && MISSION_DIR="$gitdir/lcars/missions/$MISSION_ID"
  fi
  resolve_worker_bin
  local m; m="$(resolve_stage_model "$key")"
  printf 'STAGE-MODEL key=%s model=%s\n' "$key" "${m:--}"
}

# The `spawn-stage <role>` subcommand: drive the REAL worker_spawn chokepoint for
# an env ROLE through whatever worker bin is set (a stub in tests), so the spawned
# argv — including any per-stage --model — is observable end-to-end. Mission-aware
# (estimate.json lives under --mission's dir). Not used in production flows; it is
# the spawn-path test surface paralleling resolve-stage-model.
cmd_spawn_stage() { # role (positional, in $1)
  local role="$1" gitdir
  gitdir="$("$GIT_BIN" rev-parse --git-common-dir 2>/dev/null)" || gitdir=""
  if [ -n "$gitdir" ]; then
    case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
    LCARS_CFG="$gitdir/lcars/config.json"
    [ -n "${MISSION_ID:-}" ] && MISSION_DIR="$gitdir/lcars/missions/$MISSION_ID"
  fi
  resolve_worker_bin
  resolve_worker_model
  local outdir; outdir="$(mktemp -d)"
  LCARS_WORKER_ROLE="$role" worker_spawn "repo-read" "$outdir" "test prompt"
  rm -rf "$outdir"
}

# Resolve both ONCE per process, then print the self-explaining log line naming
# the resolved cli + model + the SOURCE that won (env/config/detected/default for
# the bin; env/config/unset for the model). Idempotent: the guard means repeated
# calls (one per Stage advance) re-resolve but print the line only once.
resolve_worker() {
  resolve_worker_bin
  resolve_worker_model
  [ "$WORKER_RESOLVED" = "1" ] && return 0
  WORKER_RESOLVED=1
  # The self-explaining line goes to STDERR: the worker-using Stage drivers print
  # their machine-readable artifacts (e.g. context-source's pack PATH) to STDOUT,
  # and this human line must not pollute those surfaces. It still shows in a normal
  # `lcars run` (stderr is on the captain's terminal).
  printf '  worker: %s (bin: %s) model=%s (model: %s)\n' \
    "$(basename "$WORKER_BIN")" "$WORKER_BIN_SRC" \
    "${WORKER_MODEL:--}" "$WORKER_MODEL_SRC" >&2
}

# The `resolve-worker` subcommand: a thin, mission-free test surface over the
# resolver. It resolves $LCARS_CFG from the repo's shared git dir (so config.json
# participates), runs resolve_worker (which prints the human log line), then
# prints a machine-readable summary line the tests assert on. No LLM, no mission.
cmd_resolve_worker() {
  local gitdir
  gitdir="$("$GIT_BIN" rev-parse --git-common-dir 2>/dev/null)" || gitdir=""
  if [ -n "$gitdir" ]; then
    case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
    LCARS_CFG="$gitdir/lcars/config.json"
  fi
  resolve_worker
  printf 'WORKER-RESOLVED bin=%s binsrc=%s model=%s modelsrc=%s\n' \
    "$(basename "$WORKER_BIN")" "$WORKER_BIN_SRC" \
    "${WORKER_MODEL:--}" "$WORKER_MODEL_SRC"
}

# --- delegate one cold-worker invocation to the CLI adapter -----------------
# The driver passes a role keyword + outdir + prompt; the adapter (selected by the
# cli id = basename WORKER_BIN) knows the flags and tool names. The worker binary
# itself is handed to the adapter via LCARS_WORKER_BIN (the adapter defaults it to
# the cli id otherwise). Callers may pre-export LCARS_WORKER_ROLE to override the
# env role the worker sees while still selecting the toolset by <role> (the
# context-pack case): the adapter never overwrites an already-set LCARS_WORKER_ROLE.
worker_spawn() { # role outdir prompt
  local role="$1" outdir="$2" prompt="$3"
  # The cli id selects the adapter. It is the basename of the worker binary
  # (`claude` in production) — this indirection is the whole point: a future
  # `copilot` binary routes to a copilot adapter case automatically. $LCARS_WORKER_CLI
  # overrides it (same spirit as LCARS_GH_BIN) so tests can point a generically
  # named stub at the claude adapter without renaming the binary.
  local cli; cli="${LCARS_WORKER_CLI:-$(basename "$WORKER_BIN")}"
  # PER-STAGE model selection (session 58): map this spawn's env-role → its stage
  # key → the resolved CLI flag, and thread THAT to the adapter (not the single
  # global $WORKER_MODEL). When the resolver yields empty the adapter emits NO
  # --model flag (session-18 argv byte-for-byte) — the legacy no-source path. The
  # model flag NAME stays cli-specific in the adapter; run.sh resolves only the
  # value here. `infra` (context-pack) is never escalated — resolve_stage_model
  # short-circuits it to the global/legacy value, so it stays exactly as today.
  local stage_key stage_model
  stage_key="$(stage_key_for_role "${LCARS_WORKER_ROLE:-$role}")"
  stage_model="$(resolve_stage_model "$stage_key")"
  # HANG-GUARD (BUG-076): wrap the cold-worker spawn so a mid-turn hang (0% CPU,
  # no output, never returns) is auto-killed and the caller's retry loop kicks in.
  # The guard polls the worker's process-group CPU% and the growth of the adapter's
  # $outdir/.worker.out/.err; a slow-but-working worker is left alone. Covers EVERY
  # cold worker (every Stage routes through here). LCARS_WORKER_HANG_SECS=0 disables.
  LCARS_WORKER_BIN="$WORKER_BIN" LCARS_WORKER_MODEL="$stage_model" \
    run_worker_hang_guarded "$outdir" \
    bash "$WORKER_ADAPTER" spawn "$cli" "$role" "$outdir" "$prompt"
}

# --- refuse to run a Stage without a real worker, LOUDLY --------------------
# The point of this build is that headless Stages are isolated, never inline. If
# no worker binary is available we must NOT silently pretend isolation — we stop
# and say so, so an inline/uncovered run can never masquerade as `⊘ isolated`.
require_worker() {
  # Resolve WHICH cli (+ model) to run as the worker FIRST — at run time, after
  # locate_mission has set $LCARS_CFG so config.json can participate. This is the
  # single chokepoint every worker-using Stage (and the context-pack path) hits,
  # so the self-explaining resolution line prints exactly once per process.
  resolve_worker
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
spawn_worker() { # role  template  toolset  outdir  extra  [prior_no_file]
  local role="$1" template="$2" toolset="$3" outdir="$4" extra="$5" prior_no_file="${6:-}"
  mkdir -p "$outdir"
  # Lever 2 — behaviour-keyed retry escalation. When a PRIOR attempt of THIS
  # single-worker stage produced NO file (the procrastination failure mode), the
  # caller passes a non-empty $prior_no_file; only then do we append an escalation
  # block, keyed purely on the observed behaviour (no CLI name). The FIRST attempt
  # passes nothing, so its prompt stays byte-for-byte unchanged.
  local prior_fail_block=""
  if [ -n "$prior_no_file" ]; then
    prior_fail_block="

## YOUR PREVIOUS ATTEMPT FAILED — read this FIRST
A prior attempt at this exact task ended its turn WITHOUT creating the required
output file: it described the task but never called its file-creation / file-
writing tool, so no file reached the scratch output directory and the attempt
counted as no output. Do NOT repeat that. This time, your FIRST action — before
any analysis, explanation, or prose — MUST be to call your file-creation tool to
create the required output file in the scratch output directory — in a single
write, with its COMPLETE final content (do NOT create an empty or placeholder file
intending to fill it in later; your file-creation tool may not support overwriting
an existing file). Describing the task is NOT doing it."
  fi
  local prompt
  prompt="$(cat "$template")

$extra

## Where to write your output — READ THIS, IT IS NOT OPTIONAL
Your scratch output directory is: $outdir
You MAY first read your input files (read tools are allowed), but you MUST then
CREATE each output file specified above with your file-creation / file-writing
tool. Create each output file ONCE, with its COMPLETE final content, in a single
write — do NOT create an empty or placeholder file intending to edit or fill it
in later, because your file-creation tool may not support overwriting a file that
already exists. That tool IS available to you in this session, so do NOT claim you
lack one or that this session is read-only.
You MUST create the output file(s) — with their full final content — BEFORE you
end your turn. Do NOT end your turn by merely announcing or describing what you
will do — describing the task is NOT doing it. Your turn is NOT complete until the
file(s) exist on disk in the scratch output directory.
The harness reads ONLY the files you create in that scratch output directory; it
NEVER reads your reply. Do NOT put your answer in your reply / chat — a
reply-only answer counts as no output and FAILS the stage. Create the file(s)
exactly as specified above, in the scratch output directory, and nowhere else.$prior_fail_block"
  # The env role the worker sees IS this Stage's role; the toolset is selected by
  # $toolset. They coincide for every Stage spawn (only the context-pack path
  # differs, and that goes through generate_context_pack, not here), so pre-export
  # LCARS_WORKER_ROLE=$role and pass $toolset as the adapter's toolset-role.
  LCARS_WORKER_ROLE="$role" worker_spawn "$toolset" "$outdir" "$prompt"
}

# === Bounded fan-out (the ONE shared concurrency helper) ====================
# Runs a list of jobs CONCURRENTLY with a hard cap so a wide wave (or a many-
# question Research) never spawns an unbounded swarm. Pure POSIX job control —
# no GNU `xargs -P`, no `wait -n` (absent on the bash the harness targets). The
# cap is $LCARS_MAX_PARALLEL (default 4, floored at 1); a non-numeric value
# falls back to the default so a stray env var can never disable the cap.
#
#   run_capped <<EOF
#   <shell command line 1>
#   <shell command line 2>
#   ...
#   EOF
#
# Each NON-EMPTY stdin line is one job: it is run via `bash -c` in the background,
# and the helper blocks until a slot frees before launching the next. It returns
# 0 iff EVERY job exited 0 (so a single failure surfaces to the caller); the jobs
# all run regardless. Output ordering is finish-order — callers that need a
# deterministic RECORD order must re-read their results in their own order
# afterwards (cmd_implement does this in plan order).
max_parallel() {
  local n="${LCARS_MAX_PARALLEL:-4}"
  case "$n" in ''|*[!0-9]*) n=4 ;; esac
  [ "$n" -ge 1 ] 2>/dev/null || n=4
  printf '%s' "$n"
}
run_capped() { # jobs on stdin, one shell command per line
  local cap; cap="$(max_parallel)"
  local pids="" rc=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Block until a slot is free: while the number of live children >= cap, reap.
    while [ "$(printf '%s\n' $pids | grep -c .)" -ge "$cap" ]; do
      local alive="" p
      for p in $pids; do
        if kill -0 "$p" 2>/dev/null; then
          alive="$alive $p"
        else
          wait "$p" 2>/dev/null || rc=1
        fi
      done
      pids="$alive"
      [ "$(printf '%s\n' $pids | grep -c .)" -ge "$cap" ] && sleep 0.02
    done
    bash -c "$line" &
    pids="$pids $!"
  done
  # Drain the rest.
  local p
  for p in $pids; do wait "$p" 2>/dev/null || rc=1; done
  return "$rc"
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

  # GROUNDING MODE (logged bug). A bug filed via `lcars log` carries origin=="log"
  # (fallback type=="bug") and enters the pipeline at Research NOT to generate open
  # questions, but to ANCHOR the reported symptom to the EXISTING code the feature
  # already ships — so the downstream plan MODIFIES the real implementation instead
  # of building a parallel decoy (the sun/moon-icon regression). Grounding runs ONE
  # bounded, read-only worker fed the bug PRD + the PARENT Mission's PRD/plan, writes
  # research/grounding.json, and advances to Validate. It NEVER generates questions,
  # NEVER fans out per-question agents, and can NEVER escalate to awaiting-human.
  local m_origin m_type
  m_origin="$(json_str "$STATE" origin)"
  m_type="$(json_str "$STATE" type)"
  if [ "$m_origin" = "log" ] || [ "$m_type" = "bug" ]; then
    cmd_research_grounding
    return $?
  fi
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
    # The captain's durable image attachments (S92) ride in by ABSOLUTE path so
    # the question-generator can view them as input; empty when none exist.
    local rq_extra="## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/prd.md"
    rq_extra="$rq_extra$(attachments_extra_block)"
    # Pin the reader to the Mission's own branch, not the ambient checkout.
    rq_extra="$rq_extra$(mission_branch_block)"
    spawn_worker research-questions "$STAGES_DIR/research-questions.md" repo-read "$qdir" \
      "$rq_extra" "$( [ "$tries" -gt 1 ] && printf no-file )"
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
  # Fan out via the SHARED bounded-cap helper (run_capped) so a many-question
  # Research never spawns an unbounded swarm — same cap ($LCARS_MAX_PARALLEL) the
  # wave's tickets use. Each job re-enters THIS script's research-agent path with
  # ONLY its question + outdir (purity intact — the agent prompt is question-only;
  # run_capped adds nothing). Args ride the environment, %q-quoted, so a question
  # with any shell metacharacter can never break the job line `bash -c` evaluates.
  local resp; resp="$(mktemp -d)"
  local i=0 q
  local jobs; jobs="$(mktemp)"
  # Resolve the RESEARCH-stage model flag ONCE (per-stage seam, session 58) and
  # thread it into every fan-out agent's env below — see the CRITICAL note there.
  local ra_model; ra_model="$(resolve_stage_model research)"
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    i=$((i + 1))
    local adir; adir="$resp/$(printf '%03d' "$i")"
    # Pass the PARENT's already-resolved worker bin into each agent job so the
    # agent subprocess runs the SAME cold-worker CLI without re-detecting the host.
    # CRITICAL (session 58): pass the RESOLVED RESEARCH-STAGE model flag — NOT the
    # raw global $WORKER_MODEL. Each agent re-enters this script as a fresh process
    # where env precedence (LCARS_WORKER_MODEL) PINS the model; if we passed the
    # global value the per-stage research selection (e.g. research→opus from
    # estimate.json) would be silently lost for every fan-out agent. The child sees
    # this as a verbatim env pin (resolve_stage_model returns it unchanged), which
    # is exactly the research-stage flag we resolved here. Empty ⇒ unset ⇒ the
    # child emits NO --model flag (legacy byte-identical path).
    printf 'LCARS_RA_DIR=%q LCARS_RA_Q=%q LCARS_WORKER_BIN=%q LCARS_WORKER_MODEL=%q bash %q research-agent-job\n' \
      "$adir" "$q" "$WORKER_BIN" "$ra_model" "$SELF" >>"$jobs"
  done < <(grep -ve '^[[:space:]]*$' "$qdir/questions.txt")
  run_capped <"$jobs" || true
  rm -f "$jobs"

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

# === Research: GROUNDING mode (logged bug) =================================
# A logged bug enters Research not to open questions but to ANCHOR its symptom to
# the EXISTING code the feature already ships. This runs ONE bounded, read-only
# cold worker fed the bug PRD + the PARENT Mission's PRD/plan (the highest-signal
# map of the real symbols), writes research/grounding.json, and advances to
# Validate — which consumes research/*.json automatically. NO question-gen, NO
# per-question fan-out, and NO awaiting-human escalation is EVER reachable here.
# Called from cmd_research (already locate_mission'd, require_stage align,
# require_worker'd, prd.md verified).
cmd_research_grounding() {
  # Locate the PARENT Mission's artifacts — the parent's plan names the real
  # symbols (e.g. themeStore.toggleTheme), so it is the strongest anchor.
  local parent missions_root parent_dir parent_branch
  parent="$(json_str "$STATE" parentMission)"
  missions_root="$(dirname "$MISSION_DIR")"
  [ -n "$parent" ] && parent_dir="$missions_root/$parent" || parent_dir=""

  # Assemble the worker prompt from artifact PATHS only (cold-worker discipline).
  local extra="## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/prd.md   (the bug symptom, as the captain reported it — casual language)"
  if [ -n "$parent_dir" ] && [ -d "$parent_dir" ]; then
    [ -f "$parent_dir/prd.md" ] && extra="$extra
- $parent_dir/prd.md   (the PARENT Mission's PRD — what the existing feature was built to do)"
    [ -f "$parent_dir/validated-plan.md" ] && extra="$extra
- $parent_dir/validated-plan.md   (the PARENT's validated plan — the intended design of the existing feature)"
    [ -f "$parent_dir/plan.json" ] && extra="$extra
- $parent_dir/plan.json   (the PARENT's ticket plan — HIGHEST SIGNAL: it names the real files/symbols/components the feature already ships; ground the symptom in these)"
    # A pointer to the parent's delivered code so the worker inspects the ACTUAL
    # implementation (read-only repo access is already granted by the toolset).
    parent_branch="$(json_str "$parent_dir/state.json" branch)"
  fi
  [ -n "$parent_branch" ] || parent_branch="$(json_str "$STATE" base)"
  if [ -n "$parent_branch" ]; then
    extra="$extra

## Where the delivered code lives
The existing feature's code was delivered on branch \`$parent_branch\`. Inspect
the actual implementation there (read-only) to confirm the real targets — do not
guess from the plan alone."
  fi
  # S92 attachments ride into grounding too: a logged bug's screenshot is often
  # THE symptom — the grounding worker must see it like every other cold stage.
  extra="$extra$(context_extra_block)$(attachments_extra_block)"

  # ONE bounded worker, retried on a no-file attempt (same lever as validate).
  local tries=0 prior_no_file=""
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    local odir; odir="$(mktemp -d)"
    spawn_worker research-grounding "$STAGES_DIR/research-grounding.md" repo-read "$odir" "$extra" "$prior_no_file"
    if [ -f "$odir/grounding.json" ]; then
      mkdir -p "$MISSION_DIR/research"
      cp "$odir/grounding.json" "$MISSION_DIR/research/grounding.json"
      rm -rf "$odir"
      advance   # stage align → validate, label align → validate (same path as save)
      echo "GROUND: bug anchored to existing code"
      echo "  Grounding worker anchored the symptom to the existing implementation."
      echo "  Saved research/grounding.json."
      echo "  Stage:  validate"
      [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
      isolated_line research 1
      return 0
    fi
    prior_no_file=no-file
    rm -rf "$odir"
  done
  die "the grounding worker produced no grounding.json after $MAX_WORKER_TRIES attempt(s) — Stage stopped, no advance."
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
  # A logged bug's Research runs in grounding mode and leaves research/grounding.json
  # (targets/kind/restated/reuse_directive). When present, direct the Validator to
  # anchor the plan to the EXISTING code it names — modify those targets, do NOT
  # stand up a parallel/duplicate mechanism (the sun/moon-icon regression this cures).
  [ -f "$MISSION_DIR/research/grounding.json" ] && extra="$extra
  NOTE: research/grounding.json is a GROUNDING artifact — it names the EXISTING code (targets) this bug is about and a reuse_directive. The validated plan MUST modify those existing targets, NOT introduce new state/components/flags that duplicate their behaviour.
  The grounding is AUTHORITATIVE and is NOT yours to override. If you conclude the grounded targets are already correct, that the bug is already fixed, or that the grounding is stale/wrong, do NOT emit validated-plan.md (in particular NOT a no-op 'already fixed' verification plan). Instead emit scope.txt with a single plain-language question for the human describing the discrepancy (what the grounding says vs. what you found), and stop — the harness routes that to the captain via the existing scope gate."
  # RESUME after `lcars respond`: the captain's recorded answer resolves the
  # prior scope question. Feed it so the fresh Validator FOLDS IT IN and does not
  # re-raise the same question — otherwise the awaiting-human gate loops forever.
  [ -f "$MISSION_DIR/answers.json" ] && extra="$extra
- $MISSION_DIR/answers.json   (the captain's answer resolving the prior scope question — treat it as DECIDED and fold it in; do not re-raise it)"
  # The engineering ADRs Align seeded for a complex Mission (Context / Decision /
  # Alternatives / Consequences). Align SEEDS them; Validate may REFINE them when
  # a research finding changes a decision (option B) — so feed the path when it
  # exists. A trivial Mission has no adr.md and this is simply skipped.
  [ -f "$MISSION_DIR/adr.md" ] && extra="$extra
- $MISSION_DIR/adr.md   (the engineering ADRs Align seeded; REVISE or APPEND when a finding changes a decision — emit a refined adr.md)"
  # The durable repo context source (CONTEXT.md or the generated pack) — shared
  # declarative facts, by PATH only. Safe for this declarative Stage.
  extra="$extra$(context_extra_block)"
  # The captain's durable image attachments (S92) — ABSOLUTE paths, read as input.
  extra="$extra$(attachments_extra_block)"
  # Pin the reader to the Mission's own branch, not the ambient checkout.
  extra="$extra$(mission_branch_block)"

  local tries=0 prior_no_file=""
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    local odir; odir="$(mktemp -d)"
    spawn_worker validate "$STAGES_DIR/validate.md" repo-read "$odir" "$extra" "$prior_no_file"
    # Lever 2: if this attempt produced NEITHER expected file, the next retry gets
    # the procrastination escalation; a produced-but-malformed file does not.
    if [ ! -f "$odir/scope.txt" ] && [ ! -f "$odir/validated-plan.md" ]; then
      prior_no_file=no-file
    else
      prior_no_file=""
    fi

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
      if [ "$rc" -eq 0 ]; then
        # Option B: Align SEEDS the ADRs, Validate REFINES them. If the worker
        # emitted a refined adr.md (a finding changed a decision), persist it back
        # into the mission dir — mirroring the validated-plan.md copy — so every
        # downstream worker reads the up-to-date frame, not the stale Align seed.
        [ -f "$odir/adr.md" ] && cp "$odir/adr.md" "$MISSION_DIR/adr.md"
        isolated_line validate 1; rm -rf "$odir"; exit 0
      fi
    fi
    rm -rf "$odir"
  done
  die "the Validate worker produced an artifact that failed validation after $MAX_WORKER_TRIES attempt(s) — Stage stopped, no advance."
}

# === Estimator (session 59) ================================================
# Runs at the END of Align (driven by lcars-file once prd.md/adr.md + state.json
# exist). One cold REPO-READ worker reads prd.md + adr.md + the repo context and
# inspects relevant code, then writes estimate.json: two criticality scores + a
# per-stage model map (logical tiers) that S58's resolve_stage_model CONSUMES.
#
# CRITICAL CONTRACTS:
#  - The estimator must NEVER block filing. cmd_estimate degrades exactly like the
#    gh-missing path in file.sh: on no/invalid output after the retries it leaves
#    NO estimate.json and exits non-zero with a note, and lcars-file files the
#    mission anyway (every downstream stage then falls back to its legacy model).
#  - The estimator runs on ITS OWN model (default tier "opus", config
#    `estimatorModel`), NOT a per-stage map. We pin it for this one spawn by
#    exporting LCARS_WORKER_MODEL (env pin wins in resolve_stage_model), so the
#    estimator never escalates other stages and its own spawn uses the right model.

# Validate the worker's estimate.json into a clean, canonical estimate.json at
# $MISSION_DIR/estimate.json. Returns 0 on success (file written), non-zero on a
# malformed payload (nothing written). Pure bash + the jq-free readers — no LLM.
estimate_validate_and_write() { # src-json
  local src="$1"
  [ -f "$src" ] || return 1
  local enum='^(low|medium|high)$' tierre='^(sonnet|opus)$'
  local rc ic; rc="$(json_scoped_str "$src" reasoningCriticality)"; ic="$(json_scoped_str "$src" implCriticality)"
  printf '%s' "$rc" | grep -Eq "$enum" || return 1
  printf '%s' "$ic" | grep -Eq "$enum" || return 1
  # --- SINGLE-SOURCE active stage list (S74 bug-awareness) -------------------
  # The estimator worker scores all six stages, but a LOGGED BUG fast-tracks
  # straight to Plan (lcars-log: child state.json stage="plan", type="bug") and
  # NEVER runs Research or Validate. So when the mission being estimated is a bug
  # we canonicalize the estimate.json down to ONLY the stages it actually runs —
  # plan, planReview, implement, verify — dropping research+validate from the
  # models / tokenEstimates / requestEstimates maps. The cost is then computed
  # over exactly the stages present in the file (cost_compute reads the file's
  # stage set), so it sums the 4 real stages for a bug and all 6 otherwise. One
  # list drives the validation loops, the emit, AND the cost — no second model.
  local STAGE_KEYS="research validate plan planReview implement verify"
  local mtype="" mstage=""
  if [ -f "$MISSION_DIR/state.json" ]; then
    mtype="$(json_scoped_str "$MISSION_DIR/state.json" type)"
    mstage="$(json_scoped_str "$MISSION_DIR/state.json" stage)"
  fi
  # The fast-tracked LOGGED bug — and ONLY that — skips Research + Validate. Its
  # signal is BOTH type=="bug" AND stage=="plan" at estimate time (lcars-log seeds
  # the child straight at Plan; see log.sh). A regular `lcars file` bug also has
  # type=="bug" but is estimated at stage=="align" and runs the FULL pipeline — so
  # type alone is NOT enough; the stage is what proves Research/Validate were skipped.
  if [ "$mtype" = "bug" ] && [ "$mstage" = "plan" ]; then
    STAGE_KEYS="plan planReview implement verify"
  fi
  # The active stage keys' model values must be present and each a valid tier.
  # (For a bug we only require/keep the 4 it runs; the worker may still have
  # scored six — we simply ignore research/validate.)
  local k v
  for k in $STAGE_KEYS; do
    v="$(json_scoped_str "$src" "models.$k")"
    printf '%s' "$v" | grep -Eq "$tierre" || return 1
    eval "TIER_$k=\$v"
  done
  # estimatorModel: a free-form model-name string. Read RAW + fully decode so any
  # JSON-hostile char in it round-trips, then it is re-encoded on emit via the
  # single JSON encoder (S69 — was previously emitted bare → could break the file).
  local em; em="$(json_decode_string "$(json_scoped_raw "$src" estimatorModel)")"; [ -n "$em" ] || em="opus"
  # --- schemaVersion-2 fields (session 60) ---------------------------------
  # Per-stage TOKEN + REQUEST estimates. Repair malformed/absent worker output:
  # a non-negative integer survives; anything else (missing key, junk, negative)
  # canonicalizes to 0 so the file is always well-formed and the cost is defined.
  local n
  for k in $STAGE_KEYS; do
    n="$(json_scoped_num "$src" "tokenEstimates.$k.low")";   eval "TOKLO_$k=\$(canon_nonneg_int \"\$n\")"
    n="$(json_scoped_num "$src" "tokenEstimates.$k.high")";  eval "TOKHI_$k=\$(canon_nonneg_int \"\$n\")"
    n="$(json_scoped_num "$src" "requestEstimates.$k.low")"; eval "REQLO_$k=\$(canon_nonneg_int \"\$n\")"
    n="$(json_scoped_num "$src" "requestEstimates.$k.high")";eval "REQHI_$k=\$(canon_nonneg_int \"\$n\")"
  done
  # rationale: a single JSON string, repaired to AT MOST 2 paragraphs (blank-line
  # separated). We read the RAW token and FULLY decode it (json_scoped_raw +
  # json_decode_string) so \n / \t / \\ / \" all become their literal characters
  # UNAMBIGUOUSLY — the old half-decode (json_scoped_str) conflated a literal
  # backslash with a \n escape introducer, which is the S69 corruption bug. The
  # clamp then splits on a REAL blank line, and the FINAL escaping is done once,
  # robustly, through the single JSON encoder (see _estimate_emit). This makes a
  # rationale carrying an embedded quote, newline OR backslash round-trip as VALID
  # JSON (S74's logged-bug path exercises the same code so the fix holds there too).
  local rationale; rationale="$(json_decode_string "$(json_scoped_raw "$src" rationale)")"
  rationale="$(rationale_clamp "$rationale")"
  # Encode every worker-derived STRING field through the SINGLE JSON encoder so the
  # canonical file is always valid JSON, whatever chars the worker emitted (S69).
  # Each token below ALREADY INCLUDES its surrounding quotes. For clean input the
  # encoder produces exactly `"<s>"` — byte-identical to the old printf '"%s"'.
  local rationale_tok; rationale_tok="$(json_encode_string "$rationale")"
  local em_tok; em_tok="$(json_encode_string "$em")"
  # Re-emit a CANONICAL estimate.json. The `cost` block is COMPUTED BY CODE from
  # the token/request estimates + pricing.json + the active CLI — NEVER trusted
  # from the worker. We write the file once WITHOUT cost, compute against it, then
  # write the final file with the computed cost block embedded.
  local devs; devs="$(estimate_extract_deviations "$src")"
  local cli; cli="${LCARS_WORKER_CLI:-$(basename "${WORKER_BIN:-claude}")}"
  local out="$MISSION_DIR/estimate.json"
  _estimate_emit() { # cost-block-or-empty
    local cost="$1"
    printf '{\n'
    printf '  "schemaVersion": 3,\n'
    printf '  "reasoningCriticality": "%s",\n' "$rc"
    printf '  "implCriticality": "%s",\n' "$ic"
    # models / tokenEstimates / requestEstimates are emitted over EXACTLY the
    # active stage keys ($STAGE_KEYS — 4 for a bug, 6 otherwise), comma-joined
    # so the JSON stays valid for either set.
    local _ek _sep _tv _tklo _tkhi _rqlo _rqhi
    printf '  "models": {\n'
    _sep=""
    for _ek in $STAGE_KEYS; do
      eval "_tv=\$TIER_$_ek"
      printf '%s    "%s": "%s"' "$_sep" "$_ek" "$_tv"; _sep=$',\n'
    done
    printf '\n  },\n'
    printf '  "tokenEstimates": {\n'
    _sep=""
    for _ek in $STAGE_KEYS; do
      eval "_tklo=\$TOKLO_$_ek"; eval "_tkhi=\$TOKHI_$_ek"
      printf '%s    "%s": { "low": %s, "high": %s }' "$_sep" "$_ek" "$_tklo" "$_tkhi"; _sep=$',\n'
    done
    printf '\n  },\n'
    printf '  "requestEstimates": {\n'
    _sep=""
    for _ek in $STAGE_KEYS; do
      eval "_rqlo=\$REQLO_$_ek"; eval "_rqhi=\$REQHI_$_ek"
      printf '%s    "%s": { "low": %s, "high": %s }' "$_sep" "$_ek" "$_rqlo" "$_rqhi"; _sep=$',\n'
    done
    printf '\n  },\n'
    printf '  "deviations": [%s],\n' "$devs"
    printf '  "rationale": %s,\n' "$rationale_tok"
    if [ -n "$cost" ]; then
      printf '  "cost": %s,\n' "$cost"
    fi
    printf '  "estimatorModel": %s\n' "$em_tok"
    printf '}\n'
  }
  _estimate_emit "" >"$out"
  local cost; cost="$(cost_compute "$out" "$cli")"
  _estimate_emit "$cost" >"$out"
  unset -f _estimate_emit
  return 0
}

# Canonicalize a value to a NON-NEGATIVE INTEGER: a clean non-negative integer
# survives; anything else (empty, junk, float, negative) becomes 0.
canon_nonneg_int() { # value → integer
  local v="$1"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *)           printf '%s' "$v" ;;
  esac
}

# Clamp a rationale string to AT MOST 2 paragraphs. The input is the FULLY-DECODED
# value (real newlines), so paragraphs are separated by a REAL blank line ("\n\n").
# Keeps the first two; drops the rest. The result is still a literal string — the
# single JSON encoder (json_encode_string) re-escapes it on emit, so the real
# newline survives as a proper \n token. awk's RS="" paragraph mode does the split.
rationale_clamp() { # decoded-string → decoded-string (<= 2 paragraphs)
  printf '%s' "$1" | "${LCARS_PYTHON_BIN:-python3}" -c '
import re,sys
s = sys.stdin.read()
paras = re.split(r"\n[ \t]*\n", s)
sys.stdout.write("\n\n".join(paras[:2]))
'
}

# Extract the deviations[] string entries from the worker's estimate.json and
# re-emit them as a comma-joined list of JSON strings (for the canonical file's
# `"deviations": [ … ]`). Each entry is DECODED then RE-ENCODED through the single
# JSON encoder, so an entry carrying a quote, newline or backslash round-trips as
# VALID JSON (S69 — they were previously copied verbatim with no re-escaping). The
# output matches the old `, `-joined, space-padded form, so a CLEAN array renders
# byte-identically. Empty/absent array → empty output. jq-free (stdlib python).
estimate_extract_deviations() { # src-json → ` "a", "b" ` or empty
  local src="$1" body
  body="$(tr -d '\n' <"$src" | sed -En 's/.*"deviations"[[:space:]]*:[[:space:]]*\[([^]]*)\].*/\1/p')"
  [ -n "$body" ] || { printf ''; return 0; }
  # Pull each raw "double-quoted" token (incl. embedded escapes), then decode +
  # re-encode each so the canonical entry is correctly escaped exactly once.
  printf '%s' "$body" | "${LCARS_PYTHON_BIN:-python3}" -c '
import json,re,sys
body = sys.stdin.read()
# Match JSON string tokens, honouring backslash escapes, in array order.
toks = re.findall(r"\"(?:[^\"\\]|\\.)*\"", body)
out = []
for t in toks:
    try:
        val = json.loads(t)            # decode the raw token to its literal value
    except Exception:
        continue
    out.append(json.dumps(val))        # re-encode → correctly-escaped token
if out:
    sys.stdout.write(" " + ", ".join(out) + " ")
'
}

cmd_estimate() {
  locate_mission "$MISSION_ID"
  require_worker
  [ -f "$MISSION_DIR/prd.md" ] || die "no prd.md — Align has not produced a PRD yet."

  # Pin the estimator's own model. Tier "opus" by default, config-overridable via
  # config.json estimatorModel; translate the tier through the active CLI's alias
  # map so copilot gets claude-opus-4.8, claude gets opus. An empty translation
  # (a tier the alias map doesn't know) means NO --model flag — never a failure.
  local est_tier="opus"
  local cfg_tier=""
  [ -n "${LCARS_CFG:-}" ] && [ -f "${LCARS_CFG:-}" ] && cfg_tier="$(json_str "$LCARS_CFG" estimatorModel)"
  [ -n "$cfg_tier" ] && est_tier="$cfg_tier"
  local cli; cli="${LCARS_WORKER_CLI:-$(basename "${WORKER_BIN:-claude}")}"
  local est_model; est_model="$(alias_for_tier "$cli" "$est_tier")"

  local extra="## Read these artifacts (your inputs)
- $MISSION_DIR/prd.md"
  [ -f "$MISSION_DIR/adr.md" ] && extra="$extra
- $MISSION_DIR/adr.md   (the engineering ADRs Align seeded — read for the architectural frame)"
  # Shared declarative repo facts, by PATH only (same as every repo-read Stage).
  extra="$extra$(context_extra_block)"
  # Tell the worker which tier it ran on so it can echo it into estimatorModel.
  extra="$extra

## Your model tier
estimatorModel = \"$est_tier\" — echo this verbatim into the estimate.json field."

  local tries=0 prior_no_file=""
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    local odir; odir="$(mktemp -d)"
    # Pin the estimator's OWN model for just this spawn via the env pin (it wins
    # in resolve_stage_model for every key, but this is a one-shot estimator spawn
    # with no stage role, so it only affects this call). When $est_model is empty
    # the env stays unset and the adapter emits NO --model — legacy-safe.
    if [ -n "$est_model" ]; then
      LCARS_WORKER_MODEL="$est_model" spawn_worker estimate "$STAGES_DIR/estimate.md" repo-read "$odir" "$extra" "$prior_no_file"
    else
      spawn_worker estimate "$STAGES_DIR/estimate.md" repo-read "$odir" "$extra" "$prior_no_file"
    fi
    if [ ! -f "$odir/estimate.json" ]; then
      prior_no_file=no-file; rm -rf "$odir"; continue
    fi
    prior_no_file=""
    if estimate_validate_and_write "$odir/estimate.json"; then
      isolated_line estimate 1; rm -rf "$odir"; exit 0
    fi
    rm -rf "$odir"
  done
  # Degradation parity with gh-missing: no estimate.json, but do NOT crash the
  # caller's filing. lcars-file treats a non-zero exit as "no estimate" and files
  # the mission anyway; every stage then falls back to its legacy model.
  printf '  ⚠ estimator produced no valid estimate.json after %s attempt(s) — mission keeps default models.\n' "$MAX_WORKER_TRIES" >&2
  exit 1
}

# === CLI-aware mission cost (session 60) ===================================
# The estimator emits a per-stage TOKEN estimate (Claude billing) and a per-stage
# REQUEST-COUNT estimate (Copilot billing). The CODE — never the model — turns
# those into a reproducible cost figure in the ACTIVE CLI's native unit, reading
# every price/multiplier from pricing.json (PRICING_FILE). Pure: no LLM, no spawn.
#
# CLAUDE billing model (unit "usd"): each stage's tokens are billed against THAT
# stage's tier ($/MTok from pricing.json), split 80% input / 20% output (a fixed,
# documented split so the figure is deterministic and reproducible — agentic coding
# is input-heavy). Per stage, per bound b∈{low,high}:
#   stage_usd(b) = tokens(b) * (0.8*inputPerMTok[tier] + 0.2*outputPerMTok[tier]) / 1e6
# cost.usd.{low,high} = Σ over the six stages.
#
# COPILOT billing model (unit "premiumRequests"): each stage invocation is a
# premium request weighted by its tier multiplier (pricing.json). Per bound:
#   premiumRequests(b) = Σ requests(b) * premiumRequestMultiplier[tier]
# usdOverage(b) = premiumRequests(b) * overagePerRequest (or null if rate unset).
# If any active-tier multiplier (or the overage rate) is unset/null in pricing.json
# the figure is "unavailable" — we print a marker, NEVER a wrong number.
COST_INPUT_SPLIT="0.8"   # share of tokens billed at the input rate (doc'd above)
COST_OUTPUT_SPLIT="0.2"  # …the remainder at the output rate. Sum MUST be 1.

# === Copilot billing-model selector (session 64) ===========================
# GitHub moved Copilot to USAGE-BASED (token / GitHub AI Credits) billing on
# 2026-06-01; the legacy PREMIUM-REQUEST scheme persists only for grandfathered
# annual subscribers. The active billing model is selected per-repo:
#   config.json `copilotBilling` ∈ {"usage","legacy"}  (highest precedence)
#   → falls back to pricing.json `copilot.billingModel`
#   → final default "usage" (the new GitHub default).
copilot_billing_model() { # → "usage" | "legacy"
  local b=""
  [ -n "${LCARS_CFG:-}" ] && [ -f "${LCARS_CFG:-}" ] \
    && b="$(json_scoped_str "$LCARS_CFG" "copilotBilling")"
  if [ -z "$b" ]; then b="$(json_scoped_str "$PRICING_FILE" "copilot.billingModel")"; fi
  case "$b" in usage|legacy) printf '%s' "$b" ;; *) printf 'usage' ;; esac
}

# The captain's Copilot plan, for netting the monthly included AI-credit
# allotment: config.json `copilotPlan` ∈ {pro,proPlus,business,enterprise}.
# DEFAULT "pro" (the smallest paid tier — never over-credit a mission). The
# allotment for the plan lives in pricing.json `copilot.usage.creditAllotmentByPlan`.
copilot_plan() { # → plan key
  local p=""
  [ -n "${LCARS_CFG:-}" ] && [ -f "${LCARS_CFG:-}" ] \
    && p="$(json_scoped_str "$LCARS_CFG" "copilotPlan")"
  case "$p" in pro|proPlus|business|enterprise) printf '%s' "$p" ;; *) printf 'pro' ;; esac
}

# Sum, per bound b∈{low,high}, of each stage's token cost in USD against a tier
# rate block in pricing.json ($2 = pricing scope prefix, e.g. "claude" or
# "copilot.usage"). Reuses the documented 0.8/0.2 input/output split and the
# per-stage tier from the estimate's models map. Prints "<low> <high>" (6dp), or
# empty if ANY used tier's rates are unset/null (caller ⇒ "unavailable").
# The canonical-ordered subset of the six pipeline stages that an estimate.json
# ACTUALLY carries in its `models` block. A logged bug's canonical estimate.json
# omits research+validate (S74), so this returns its 4 real stages; a feature's
# returns all six. The cost math iterates THIS set, so it auto-sums the right
# stages for either mission type — one source (the file's stage set), no fork.
estimate_active_stages() { # estimate-json → space-separated stage keys (in order)
  local est="$1" k out=""
  for k in research validate plan planReview implement verify; do
    [ -n "$(json_scoped_str "$est" "models.$k")" ] && out="$out $k"
  done
  printf '%s' "${out# }"
}

cost_token_usd() { # estimate-json pricing-scope → "low high" | ""
  local est="$1" scope="$2"
  local stages; stages="$(estimate_active_stages "$est")"
  local usd_low=0 usd_high=0 k tier inr outr tlo thi
  for k in $stages; do
    tier="$(json_scoped_str "$est" "models.$k")"
    inr="$(json_scoped_num "$PRICING_FILE" "$scope.$tier.inputPerMTok")"
    outr="$(json_scoped_num "$PRICING_FILE" "$scope.$tier.outputPerMTok")"
    [ -n "$inr" ] && [ -n "$outr" ] || return 1
    tlo="$(json_scoped_num "$est" "tokenEstimates.$k.low")";  [ -n "$tlo" ] || tlo=0
    thi="$(json_scoped_num "$est" "tokenEstimates.$k.high")"; [ -n "$thi" ] || thi=0
    usd_low="$(awk -v a="$usd_low" -v t="$tlo" -v ir="$inr" -v or="$outr" \
      -v si="$COST_INPUT_SPLIT" -v so="$COST_OUTPUT_SPLIT" \
      'BEGIN{printf "%.6f", a + t*(si*ir + so*or)/1000000}')"
    usd_high="$(awk -v a="$usd_high" -v t="$thi" -v ir="$inr" -v or="$outr" \
      -v si="$COST_INPUT_SPLIT" -v so="$COST_OUTPUT_SPLIT" \
      'BEGIN{printf "%.6f", a + t*(si*ir + so*or)/1000000}')"
  done
  printf '%s %s' "$usd_low" "$usd_high"
}

# Compute and print the canonical "cost" JSON block (the value of the estimate's
# `cost` key, indented two spaces, no trailing comma) for one estimate.json under
# the active CLI. $1 = estimate.json path; $2 = active cli (claude|copilot).
cost_compute() { # estimate-json cli → prints the cost JSON block to stdout
  local est="$1" cli="$2"
  local pricing="$PRICING_FILE"
  # Sum over EXACTLY the stages the estimate.json carries (4 for a logged bug,
  # 6 otherwise) — the same set cost_token_usd uses, so every billing branch
  # agrees on the bug's real pipeline. (S74 bug-awareness.)
  local stages; stages="$(estimate_active_stages "$est")"
  if [ "$cli" = "copilot" ] && [ "$(copilot_billing_model)" = "usage" ]; then
    # --- USAGE-BASED (token / GitHub AI Credits) billing (session 64) --------
    # Bill tokens EXACTLY like the Claude branch against copilot.usage rates,
    # then net the plan's monthly included AI-credit allotment (credits ×
    # creditUsd = USD). Unset rates ⇒ unavailable (never a wrong number).
    local pair; pair="$(cost_token_usd "$est" "copilot.usage")" || {
      printf '{\n'
      printf '    "cli": "copilot",\n'
      printf '    "unit": "usd",\n'
      printf '    "billing": "usage",\n'
      printf '    "status": "unavailable"\n'
      printf '  }'
      return 0
    }
    local usd_low="${pair%% *}" usd_high="${pair##* }"
    local plan; plan="$(copilot_plan)"
    local credits; credits="$(json_scoped_num "$pricing" "copilot.usage.creditAllotmentByPlan.$plan")"
    [ -n "$credits" ] || credits=0
    local creditusd; creditusd="$(json_scoped_num "$pricing" "copilot.usage.creditUsd")"
    [ -n "$creditusd" ] || creditusd=0
    local included; included="$(awk -v c="$credits" -v u="$creditusd" 'BEGIN{printf "%g", c*u}')"
    local net_low net_high
    net_low="$(awk -v v="$usd_low" -v n="$included" 'BEGIN{x=v-n; if(x<0)x=0; printf "%g", x}')"
    net_high="$(awk -v v="$usd_high" -v n="$included" 'BEGIN{x=v-n; if(x<0)x=0; printf "%g", x}')"
    usd_low="$(awk -v v="$usd_low" 'BEGIN{printf "%g", v}')"
    usd_high="$(awk -v v="$usd_high" 'BEGIN{printf "%g", v}')"
    printf '{\n'
    printf '    "cli": "copilot",\n'
    printf '    "unit": "usd",\n'
    printf '    "billing": "usage",\n'
    printf '    "usd": { "low": %s, "high": %s },\n' "$usd_low" "$usd_high"
    printf '    "includedCreditsUsd": %s,\n' "$included"
    printf '    "netUsd": { "low": %s, "high": %s }\n' "$net_low" "$net_high"
    printf '  }'
    return 0
  fi
  if [ "$cli" = "copilot" ]; then
    # --- LEGACY PREMIUM-REQUEST billing (grandfathered annual subscribers) ---
    # Σ(stage requests × tier multiplier) + optional $0.04/request overage. The
    # multipliers/overage moved verbatim under copilot.legacy in session 64 — the
    # numbers and the math are byte-for-byte the S60 figure.
    # Gather per-stage tier multipliers; if any used tier (or the overage) is
    # unset/null → unavailable.
    local unavailable="" pr_low=0 pr_high=0 k tier mult rlo rhi
    local overage; overage="$(json_scoped_num "$pricing" "copilot.legacy.overagePerRequest")"
    for k in $stages; do
      tier="$(json_scoped_str "$est" "models.$k")"
      mult="$(json_scoped_num "$pricing" "copilot.legacy.$tier.premiumRequestMultiplier")"
      [ -n "$mult" ] || { unavailable=1; break; }
      rlo="$(json_scoped_num "$est" "requestEstimates.$k.low")";  [ -n "$rlo" ] || rlo=0
      rhi="$(json_scoped_num "$est" "requestEstimates.$k.high")"; [ -n "$rhi" ] || rhi=0
      pr_low="$(awk -v a="$pr_low" -v r="$rlo" -v m="$mult" 'BEGIN{printf "%d", a + r*m}')"
      pr_high="$(awk -v a="$pr_high" -v r="$rhi" -v m="$mult" 'BEGIN{printf "%d", a + r*m}')"
    done
    if [ -n "$unavailable" ]; then
      printf '{\n'
      printf '    "cli": "copilot",\n'
      printf '    "unit": "premiumRequests",\n'
      printf '    "billing": "legacy",\n'
      printf '    "status": "unavailable"\n'
      printf '  }'
      return 0
    fi
    local ov_block='null'
    if [ -n "$overage" ]; then
      local ov_lo ov_hi
      ov_lo="$(awk -v p="$pr_low" -v o="$overage" 'BEGIN{printf "%g", p*o}')"
      ov_hi="$(awk -v p="$pr_high" -v o="$overage" 'BEGIN{printf "%g", p*o}')"
      ov_block="$(printf '{ "low": %s, "high": %s }' "$ov_lo" "$ov_hi")"
    fi
    printf '{\n'
    printf '    "cli": "copilot",\n'
    printf '    "unit": "premiumRequests",\n'
    printf '    "billing": "legacy",\n'
    printf '    "premiumRequests": { "low": %s, "high": %s },\n' "$pr_low" "$pr_high"
    printf '    "usdOverage": %s\n' "$ov_block"
    printf '  }'
    return 0
  fi
  # Claude (default / unit "usd").
  local usd_low=0 usd_high=0 k tier inr outr tlo thi
  for k in $stages; do
    tier="$(json_scoped_str "$est" "models.$k")"
    inr="$(json_scoped_num "$pricing" "claude.$tier.inputPerMTok")"
    outr="$(json_scoped_num "$pricing" "claude.$tier.outputPerMTok")"
    [ -n "$inr" ] && [ -n "$outr" ] || continue
    tlo="$(json_scoped_num "$est" "tokenEstimates.$k.low")";  [ -n "$tlo" ] || tlo=0
    thi="$(json_scoped_num "$est" "tokenEstimates.$k.high")"; [ -n "$thi" ] || thi=0
    usd_low="$(awk -v a="$usd_low" -v t="$tlo" -v ir="$inr" -v or="$outr" \
      -v si="$COST_INPUT_SPLIT" -v so="$COST_OUTPUT_SPLIT" \
      'BEGIN{printf "%.6f", a + t*(si*ir + so*or)/1000000}')"
    usd_high="$(awk -v a="$usd_high" -v t="$thi" -v ir="$inr" -v or="$outr" \
      -v si="$COST_INPUT_SPLIT" -v so="$COST_OUTPUT_SPLIT" \
      'BEGIN{printf "%.6f", a + t*(si*ir + so*or)/1000000}')"
  done
  # Trim to a tidy 4-dp figure.
  usd_low="$(awk -v v="$usd_low" 'BEGIN{printf "%g", v}')"
  usd_high="$(awk -v v="$usd_high" 'BEGIN{printf "%g", v}')"
  printf '{\n'
  printf '    "cli": "claude",\n'
  printf '    "unit": "usd",\n'
  printf '    "currency": "USD",\n'
  printf '    "usd": { "low": %s, "high": %s }\n' "$usd_low" "$usd_high"
  printf '  }'
}

# The `cost --mission <id>` subcommand: a mission-free test surface over
# cost_compute, mirroring resolve-stage-model. Resolves the active CLI the same
# way (LCARS_WORKER_CLI or basename WORKER_BIN), reads the mission's estimate.json
# + pricing.json, and prints the canonical cost JSON block (plus a one-line
# `COST cli=… unit=…` header) so tests can drive it deterministically.
cmd_cost() {
  local gitdir
  gitdir="$("$GIT_BIN" rev-parse --git-common-dir 2>/dev/null)" || gitdir=""
  if [ -n "$gitdir" ]; then
    case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
    LCARS_CFG="$gitdir/lcars/config.json"
    [ -n "${MISSION_ID:-}" ] && MISSION_DIR="$gitdir/lcars/missions/$MISSION_ID"
  fi
  resolve_worker_bin
  local cli; cli="${LCARS_WORKER_CLI:-$(basename "${WORKER_BIN:-claude}")}"
  local est="$MISSION_DIR/estimate.json"
  [ -f "$est" ] || die "no estimate.json for mission ${MISSION_ID:-?}."
  local block; block="$(cost_compute "$est" "$cli")"
  printf 'COST cli=%s\n' "$cli"
  printf '%s\n' "$block"
}

# === Captain-facing estimate rendering (session 61) ========================
# Turn a mission's estimate.json into a captain-readable block in the ACTIVE
# CLI's native cost unit, for one of two SURFACES that lcars-file owns:
#   issue → a markdown "## Estimate" section (scores, a per-stage model table,
#           the cost line, the rationale) appended to the GitHub issue body.
#   cli   → a compact, two-space-indented readout (a one-line Estimate summary
#           with the scores + cost, a model-mix line, a one-line rationale).
# The cost unit tracks the active CLI: claude → "$X–$Y"; copilot → "~N premium
# requests" (+ a "$X–$Y overage" band when available, else "unavailable"). All
# of the cost-shape + active-CLI logic is reused from cost_compute — this only
# FORMATS the already-computed numbers, so the two surfaces never disagree with
# `run.sh cost`. Pure: no LLM, no spawn.

# Format a USD amount to EXACTLY two decimal places for display to the captain
# (session 64 deliverable 2). The precise value stays in estimate.json's cost
# block; this is a render-time formatting only, used by every $ figure on the
# captain surfaces (Claude band, Copilot usage band, Copilot legacy overage band).
usd2() { awk -v v="${1:-0}" 'BEGIN{printf "%.2f", v}'; }

# Pretty a logical tier ("sonnet"/"opus") for display ("Sonnet"/"Opus").
tier_display() { # tier → Tier
  case "$1" in
    opus)   printf 'Opus' ;;
    sonnet) printf 'Sonnet' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# Pretty a criticality ("low"/"medium"/"high") in UPPER case for the readout.
crit_display() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }

# Unescape a JSON string's paragraph breaks (\n\n) and newlines so the rationale
# reads as prose in the rendered surfaces. $2 = join string for blank lines.
rationale_unescape() { # escaped-string join → prose
  local s="$1" join="$2"
  s="${s//\\n\\n/$join}"
  s="${s//\\n/ }"
  s="${s//\\\"/\"}"
  s="${s//\\\\/\\}"
  printf '%s' "$s"
}

# Cost phrase for the COMPACT (cli-readout) summary, in the active CLI's unit.
# Reads the computed cost block (cost_compute output) fields via json helpers off
# the estimate.json the validator already embedded the cost into.
render_cost_compact() { # cost-json cli → e.g. "$3.62–$7.24" | "~198–396 premium reqs, ~$7.92–$15.84 overage" | "$3.62–$7.24 (AI credits)" | "unavailable"
  local est="$1" cli="$2"
  if [ "$cli" = "copilot" ]; then
    local status; status="$(json_scoped_str "$est" "cost.status")"
    if [ "$status" = "unavailable" ]; then printf 'unavailable'; return 0; fi
    local billing; billing="$(json_scoped_str "$est" "cost.billing")"
    if [ "$billing" = "usage" ]; then
      local lo hi; lo="$(json_scoped_num "$est" "cost.usd.low")"; hi="$(json_scoped_num "$est" "cost.usd.high")"
      [ -n "$lo" ] || lo=0; [ -n "$hi" ] || hi=0
      printf '$%s–$%s (AI credits)' "$(usd2 "$lo")" "$(usd2 "$hi")"
      return 0
    fi
    # legacy premium-request
    local plo phi; plo="$(json_scoped_num "$est" "cost.premiumRequests.low")"
    phi="$(json_scoped_num "$est" "cost.premiumRequests.high")"
    [ -n "$plo" ] || plo=0; [ -n "$phi" ] || phi=0
    local ovlo ovhi; ovlo="$(json_scoped_num "$est" "cost.usdOverage.low")"
    ovhi="$(json_scoped_num "$est" "cost.usdOverage.high")"
    if [ -n "$ovlo" ] && [ -n "$ovhi" ]; then
      printf '~%s–%s premium reqs, ~$%s–$%s overage' "$plo" "$phi" "$(usd2 "$ovlo")" "$(usd2 "$ovhi")"
    else
      printf '~%s–%s premium reqs' "$plo" "$phi"
    fi
    return 0
  fi
  # claude (usd)
  local lo hi; lo="$(json_scoped_num "$est" "cost.usd.low")"; hi="$(json_scoped_num "$est" "cost.usd.high")"
  [ -n "$lo" ] || lo=0; [ -n "$hi" ] || hi=0
  printf '$%s–$%s' "$(usd2 "$lo")" "$(usd2 "$hi")"
}

# Cost LINE for the ISSUE surface ("- **Cost:** …"), in the active CLI's unit.
render_cost_issue() { # cost-json cli → markdown bullet text
  local est="$1" cli="$2"
  if [ "$cli" = "copilot" ]; then
    local status; status="$(json_scoped_str "$est" "cost.status")"
    if [ "$status" = "unavailable" ]; then printf 'Copilot cost: unavailable'; return 0; fi
    local billing; billing="$(json_scoped_str "$est" "cost.billing")"
    if [ "$billing" = "usage" ]; then
      local lo hi; lo="$(json_scoped_num "$est" "cost.usd.low")"; hi="$(json_scoped_num "$est" "cost.usd.high")"
      [ -n "$lo" ] || lo=0; [ -n "$hi" ] || hi=0
      local inc; inc="$(json_scoped_num "$est" "cost.includedCreditsUsd")"; [ -n "$inc" ] || inc=0
      printf '$%s–$%s (GitHub AI Credits; first $%s/mo included on %s)' \
        "$(usd2 "$lo")" "$(usd2 "$hi")" "$(usd2 "$inc")" "$(copilot_plan)"
      return 0
    fi
    # legacy premium-request
    local plo phi; plo="$(json_scoped_num "$est" "cost.premiumRequests.low")"
    phi="$(json_scoped_num "$est" "cost.premiumRequests.high")"
    [ -n "$plo" ] || plo=0; [ -n "$phi" ] || phi=0
    local ovlo ovhi; ovlo="$(json_scoped_num "$est" "cost.usdOverage.low")"
    ovhi="$(json_scoped_num "$est" "cost.usdOverage.high")"
    if [ -n "$ovlo" ] && [ -n "$ovhi" ]; then
      printf '~%s–%s premium requests ($%s–$%s overage)' "$plo" "$phi" "$(usd2 "$ovlo")" "$(usd2 "$ovhi")"
    else
      printf '~%s–%s premium requests' "$plo" "$phi"
    fi
    return 0
  fi
  local lo hi; lo="$(json_scoped_num "$est" "cost.usd.low")"; hi="$(json_scoped_num "$est" "cost.usd.high")"
  [ -n "$lo" ] || lo=0; [ -n "$hi" ] || hi=0
  printf '$%s–$%s' "$(usd2 "$lo")" "$(usd2 "$hi")"
}

# A captain-facing phrase for the active model override, or empty when none. The
# override stores a LOGICAL TIER + a SCOPE; this is the human form the captain sees
# on the estimate surfaces so they know the estimate's model mix was overridden.
#   all            → "(override: Opus, whole run)"
#   reasoning      → "(override: Sonnet, reasoning)"
#   implementation → "(override: Opus, implementation)"
override_note() { # → "(override: …)" or empty
  local ov; ov="$(active_model_override)"
  [ -n "$ov" ] || return 0
  local scope="${ov%%:*}" tier="${ov#*:}" where
  case "$scope" in
    all)            where="whole run" ;;
    reasoning)      where="reasoning" ;;
    implementation) where="implementation" ;;
    *)              where="$scope" ;;
  esac
  printf '(override: %s, %s)' "$(tier_display "$tier")" "$where"
}

# Render the "## Estimate" markdown section for the issue body.
render_estimate_issue() { # estimate-json cli cost-json → markdown
  local est="$1" cli="$2" costfile="$3"
  local rc ic
  rc="$(json_scoped_str "$est" reasoningCriticality)"; [ -n "$rc" ] || rc="?"
  ic="$(json_scoped_str "$est" implCriticality)"; [ -n "$ic" ] || ic="?"
  printf '## Estimate\n\n'
  local ovn; ovn="$(override_note)"
  [ -n "$ovn" ] && printf '**Model override:** %s — the captain pinned the model mix; the per-stage table below shows the estimator'\''s original choice.\n\n' "$ovn"
  printf '**Criticality:** reasoning = %s · implementation = %s\n\n' \
    "$(crit_display "$rc")" "$(crit_display "$ic")"
  printf '**Per-stage model mix:**\n\n'
  printf '| Stage | Model |\n'
  printf '| --- | --- |\n'
  local k label
  for k in research validate plan planReview implement verify; do
    case "$k" in
      research)   label="Research" ;;
      validate)   label="Validate" ;;
      plan)       label="Plan" ;;
      planReview) label="Plan Review" ;;
      implement)  label="Implement" ;;
      verify)     label="Verify" ;;
      *)          label="$k" ;;
    esac
    printf '| %s | %s |\n' "$label" "$(tier_display "$(json_scoped_str "$est" "models.$k")")"
  done
  printf '\n**Estimated cost:** %s\n\n' "$(render_cost_issue "$costfile" "$cli")"
  local rationale; rationale="$(json_scoped_str "$est" rationale)"
  if [ -n "$rationale" ]; then
    printf '%s\n' "$(rationale_unescape "$rationale" '

')"
  fi
}

# Render the compact, two-space-indented readout block for the CLI stdout.
render_estimate_cli() { # estimate-json cli cost-json → indented text
  local est="$1" cli="$2" costfile="$3"
  local rc ic
  rc="$(json_scoped_str "$est" reasoningCriticality)"; [ -n "$rc" ] || rc="?"
  ic="$(json_scoped_str "$est" implCriticality)"; [ -n "$ic" ] || ic="?"
  printf '  Estimate: reasoning=%s implementation=%s  (cost %s)\n' \
    "$(crit_display "$rc")" "$(crit_display "$ic")" "$(render_cost_compact "$costfile" "$cli")"
  local ovn; ovn="$(override_note)"
  [ -n "$ovn" ] && printf '  Override: %s — model mix pinned by the captain (table below = estimator default)\n' "$ovn"
  # One-line model mix.
  printf '  Models:   research/validate=%s · plan/plan-review=%s · implement=%s · verify=%s\n' \
    "$(tier_display "$(json_scoped_str "$est" models.research)")/$(tier_display "$(json_scoped_str "$est" models.validate)")" \
    "$(tier_display "$(json_scoped_str "$est" models.plan)")/$(tier_display "$(json_scoped_str "$est" models.planReview)")" \
    "$(tier_display "$(json_scoped_str "$est" models.implement)")" \
    "$(tier_display "$(json_scoped_str "$est" models.verify)")"
  local rationale; rationale="$(json_scoped_str "$est" rationale)"
  if [ -n "$rationale" ]; then
    # First paragraph only on the readout, kept to one line.
    local first; first="$(rationale_unescape "$rationale" ' ' | tr '\n' ' ')"
    printf '  Why:      %s\n' "$first"
  fi
}

# render-estimate subcommand: read --mission's estimate.json, resolve the active
# CLI the standard way, and print the requested --surface block. If estimate.json
# is absent, print NOTHING and exit non-zero — lcars-file treats that exactly like
# an absent adr.md (no Estimate section, no crash), the load-bearing degradation.
cmd_render_estimate() { # --surface in $SURFACE
  local gitdir
  gitdir="$("$GIT_BIN" rev-parse --git-common-dir 2>/dev/null)" || gitdir=""
  if [ -n "$gitdir" ]; then
    case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
    LCARS_CFG="$gitdir/lcars/config.json"
    [ -n "${MISSION_ID:-}" ] && MISSION_DIR="$gitdir/lcars/missions/$MISSION_ID"
  fi
  resolve_worker_bin
  local cli; cli="${LCARS_WORKER_CLI:-$(basename "${WORKER_BIN:-claude}")}"
  local est="$MISSION_DIR/estimate.json"
  [ -f "$est" ] || exit 1   # absent ⇒ no output, non-zero (file.sh degradation)
  # COMPUTE the cost fresh from cost_compute (never trust a possibly-stale `cost`
  # block in estimate.json, and tolerate a fixture that omits it). Write the
  # canonical cost block to a temp JSON so the render_cost_* helpers can read its
  # nested fields with the same json_scoped_* helpers the rest of run.sh uses.
  local costblock; costblock="$(cost_compute "$est" "$cli")"
  local costfile; costfile="$(mktemp)"
  printf '{ "cost": %s }\n' "$costblock" >"$costfile"
  case "${SURFACE:-cli}" in
    issue) render_estimate_issue "$est" "$cli" "$costfile" ;;
    cli)   render_estimate_cli "$est" "$cli" "$costfile" ;;
    *)     rm -f "$costfile"; die "render-estimate: --surface must be 'issue' or 'cli' (got '${SURFACE:-}')." ;;
  esac
  rm -f "$costfile"
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
  # The engineering ADRs (Align-seeded, possibly Validate-refined) — declarative
  # architectural facts this Stage may read, by PATH only. Absent on a trivial
  # Mission, in which case this is skipped.
  [ -f "$MISSION_DIR/adr.md" ] && extra="$extra
- $MISSION_DIR/adr.md   (the engineering ADRs — architectural decisions + rationale; plan within them)"
  # Shared declarative repo facts, by PATH only.
  extra="$extra$(context_extra_block)"
  # The captain's durable image attachments (S92) — ABSOLUTE paths, read as input.
  extra="$extra$(attachments_extra_block)"
  # Pin the reader to the Mission's own branch, not the ambient checkout.
  extra="$extra$(mission_branch_block)"

  local tries=0 prior_no_file=""
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    local odir; odir="$(mktemp -d)"
    # Cold workers only CREATE FILES; the harness owns DIRECTORY scaffolding.
    # Pre-create the manifests/ subdir so the worker's `create manifests/<id>.md`
    # writes into an existing dir (some file-creation tools cannot mkdir). CLI-
    # neutral: Claude is unaffected. plan-save reads from "$odir/manifests".
    mkdir -p "$odir/manifests"
    spawn_worker plan "$STAGES_DIR/plan.md" repo-read "$odir" "$extra" "$prior_no_file"
    if [ -f "$odir/plan.json" ]; then prior_no_file=""; else prior_no_file=no-file; fi
    if [ -f "$odir/plan.json" ]; then
      local rc=0
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" plan-save \
        --mission "$MISSION_ID" --plan "$odir/plan.json" --manifests "$odir/manifests" || rc=$?
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
  # Pin the reader to the Mission's own branch, not the ambient checkout.
  extra="$extra$(mission_branch_block)"

  # S100: APPEND the SOFT under-slice hint — a heuristic, ADVISORY-ONLY signal
  # computed from each ticket's own fields (see build_slice_pressure_hint). It is
  # SIGNAL, never a verdict: it changes nothing about accept/reject (the reviewer
  # still decides), it only helps the reviewer catch a mega-ticket that hides a
  # whole surface behind a simple title. The durable BAR lives in the template.
  local sphint; sphint="$(build_slice_pressure_hint "$MISSION_DIR/plan.json" "$MISSION_DIR/manifests" "$budget")"
  [ -n "$sphint" ] && extra="$extra

$sphint"

  local tries=0 prior_no_file=""
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    local odir; odir="$(mktemp -d)"
    spawn_worker plan-review "$STAGES_DIR/plan-review.md" repo-read "$odir" "$extra" "$prior_no_file"
    if [ -f "$odir/verdict.json" ]; then prior_no_file=""; else prior_no_file=no-file; fi
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

  # --- PER-TICKET WORKTREE ISOLATION (Session 37) ------------------------------
  # When cmd_implement dispatches this ticket as one of a wave's CONCURRENT builds
  # it sets $LCARS_TICKET_WT_BASE (+ $LCARS_TICKET_BRANCH). We then create a
  # detached `git worktree` at the mission-branch tip and run THIS ticket's whole
  # build inside it — so the Test-Writer/Implementer file writes + the red-gate
  # test run never collide with a sibling ticket on the shared working tree. The
  # mission dir ($MISSION_DIR) stays SHARED (locate_mission uses --git-common-dir),
  # so result.json / events.jsonl / .commit-sha are visible to the parent. The
  # parent reads our exit code from .build-rc (written by the EXIT trap) and
  # applies the stop/flag rules deterministically in plan order. Direct
  # invocation (no $LCARS_TICKET_WT_BASE) keeps the original in-tree behaviour.
  if [ -n "${LCARS_TICKET_WT_BASE:-}" ]; then
    # Record this build's exit code for the parent, on EVERY exit path (incl. die).
    trap '__brc=$?; printf "%s" "$__brc" >"$(ticket_dir "$TICKET")/.build-rc" 2>/dev/null || :' EXIT
    local __wt
    __wt="$(make_ticket_worktree "$LCARS_TICKET_WT_BASE" "${LCARS_TICKET_BRANCH:-}" "$TICKET")" || \
      die "could not create a worktree for $TICKET — Stage stopped."
    if [ -n "$__wt" ]; then
      cd "$__wt" || die "could not enter the worktree for $TICKET."
      REPO_ROOT="$__wt"
      export LCARS_TICKET_WORKTREE="$__wt"
    fi
  fi

  # OUT-OF-WORKTREE INPUT READ GRANTS (session 76). Both halves of the adversarial
  # pair run with cwd = this ticket's ISOLATED worktree, but EVERY input they read
  # — the failing tests, manifests, approved-plan.json, adr.md, repo-map.md, the
  # context-pack, answers.json — lives under the SHARED .git/lcars/ (resolved via
  # --git-common-dir), OUTSIDE that worktree. A CLI with a hard path sandbox
  # (copilot) can otherwise read NONE of them. Hand the adapter that ONE read-dir,
  # CLI-AGNOSTICALLY (run.sh passes it for EVERY engine; the per-CLI translation —
  # copilot adds a `--add-dir`, claude ignores it — is the adapter's job). The
  # grant is READ-only and covers all inputs as a tidy superset; it never widens
  # WRITE access, so the worktree write-isolation, red gate, immutable tests, and
  # post-commit scope check are all untouched. Empty/unset for non-worktree spawns
  # ⇒ argv byte-for-byte as before.
  export LCARS_WORKER_INPUT_DIRS="$(dirname "$LCARS_CFG")"

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
  # resolved once for both halves of the adversarial pair. The captain's durable
  # image attachments (S92) ride the same artifact-paths list (ABSOLUTE paths) so
  # BOTH the Test Writer and the Implementer can view them; empty when none exist.
  local cblock; cblock="$(context_extra_block)$(attachments_extra_block)"
  # The engineering ADRs (Align-seeded, possibly Validate-refined) — declarative
  # architectural facts BOTH halves of the pair may read, by PATH only. Absent on
  # a trivial Mission, in which case this stays empty. Prepended to $cblock so it
  # rides the same artifact-paths list for both workers.
  local adrblock=""
  [ -f "$MISSION_DIR/adr.md" ] && adrblock="
- $MISSION_DIR/adr.md   (the engineering ADRs — architectural decisions this ticket must respect)"
  # Session 41: the per-ticket context manifest + the per-wave repo symbol map —
  # DECLARATIVE navigation aids (relevant files, interface signatures, touched ADR
  # ids), by PATH only, guarded on existence. Both halves of the pair read them
  # instead of cold file-walking. NEVER reaches a research worker. Empty when
  # neither artifact exists (thin greenfield / pre-wave).
  local navblock; navblock="$(implement_nav_block "$TICKET")"

  # Session 22: the Test Writer's inlined ticket spec — THIS ticket's title +
  # description + acceptanceCriteria TEXT, extracted from approved-plan.json so the
  # cold worker SEES what to test instead of having to find it in the plan (the
  # path-only handoff let a worker ground on the wrong artifact and build the wrong
  # feature). Resolved ONCE; appended under "## Your ticket" in the Phase-1 prompt
  # only — the Implementer (Phase 2) is deliberately NOT given this (its sole
  # behavioural handoff stays the failing tests, preserving the adversarial split).
  # CLI-AGNOSTIC: shared assembly, no per-CLI branch. Empty on a ticket missing
  # from the plan, so the bare id line below still carries the handoff.
  local tspecblock; tspecblock="$(ticket_spec_block "$MISSION_DIR/approved-plan.json" "$TICKET")"
  [ -n "$tspecblock" ] && tspecblock="
$tspecblock"

  # PHASE 1 — Test Writer worker → tests/ → impl-save-tests
  local tries=0 saved=0
  # REUSE PATH (Session 37 conflict rebuild): when the parent re-runs this ticket
  # to recompose a same-file edit on the UPDATED mission tip (its concurrent
  # commit could not cherry-pick), the Test Writer already ran and its immutable
  # contract is on disk (tickets/<id>/tests + tests.sha256). Re-running it would
  # re-snapshot a fresh contract and re-red-gate against the new tree — wasteful
  # and risks a different suite. So when $LCARS_REUSE_TESTS is set AND the locked
  # tests already exist, SKIP Phase 1 entirely: only the Implementer re-runs,
  # against the updated tree, exactly as the old serial in-tree path composed.
  if [ -n "${LCARS_REUSE_TESTS:-}" ] \
     && [ -d "$(ticket_dir "$TICKET")/tests" ] \
     && [ -n "$(find "$(ticket_dir "$TICKET")/tests" -type f -print -quit 2>/dev/null)" ] \
     && [ -f "$(ticket_dir "$TICKET")/tests.sha256" ]; then
    saved=1
  fi
  # GROUNDED RETRY (BUG-007): the previous naive loop re-spawned the Test Writer
  # with an IDENTICAL prompt on a red-gate rejection, so it kept producing the
  # same green-on-nothing suite until it gave up. Instead we CAPTURE the red-gate
  # signal (rc + bounded runner output + which-suite diagnosis) that impl-save-tests
  # persists to tickets/<id>/red-gate-signal.txt and FEED it into the next attempt's
  # prompt. SIGNAL ONLY — it is the harness's own gate verdict + runner stderr,
  # never the implementation and never the worker's prior reasoning (each attempt
  # is still a fresh cold worker; nothing of the prior session survives but this
  # one declarative line of feedback).
  local sigfile; sigfile="$(ticket_dir "$TICKET")/red-gate-signal.txt"
  # S96: retain the LAST attempt's worker output + files-written so, if the loop
  # exhausts without a usable suite, classify_impl_failure can name the root cause.
  local cl_worker="" cl_files=""
  # S98: separate, SHORTER budget for the EMPTY-worker (transient-CLI) case, plus a
  # flag that arms spawn_worker's re-prompt hint on the retry AFTER an empty attempt.
  local empty_tries=0 prior_empty=""
  while [ "$saved" != 1 ] && [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    # attempt = 1 + (existing ticket_attempt lines for THIS ticket+phase). Within
    # one invocation this is 1,2,3; a re-invocation continues 4,5,6 — one unique
    # index per real spawn_worker dispatch below, never a repeat.
    local awtry; awtry=$(( $(event_count ticket_attempt "\"ticket\":\"$TICKET\".*\"phase\":\"test-writer\"") + 1 ))
    emit_event ticket_attempt implement "test-writer try $awtry for $TICKET" \
      "ticket=$TICKET" "phase=test-writer" "attempt=$awtry"
    # On a retry (a prior attempt left a red-gate signal on disk), prepend the
    # captured signal so this fresh worker writes tests that genuinely fail first.
    local retryblock=""
    if [ -f "$sigfile" ]; then
      retryblock="

## RED-GATE FEEDBACK — your PREVIOUS suite was REJECTED (read this before writing)
The harness ran your last suite against the repo with NO implementation and it
did NOT fail-first. This is the gate's verdict and the runner's own output — the
ONLY thing carried over from the prior attempt (you do not see its tests, code,
or reasoning). Write tests that FAIL until the ticket's behaviour exists:
$(cat "$sigfile")"
    fi
    local odir; odir="$(mktemp -d)"
    # Harness owns directory scaffolding (workers only create files): pre-create
    # the tests/ scratch subdir so the worker's `create tests/<file>` lands without
    # needing to mkdir. CLI-neutral; Claude is unaffected. S94: ALSO pre-create the
    # stubs/ scratch subdir — the worker writes any minimal empty greenfield-module
    # stubs there (mirroring repo paths), which impl-save-tests overlays before the
    # red gate so a brand-new module's import resolves and the suite reds on an
    # assertion rather than a resolution failure.
    mkdir -p "$odir/tests" "$odir/stubs"
    spawn_worker implement-test-writer "$STAGES_DIR/implement-test-writer.md" repo-read "$odir" \
"## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/approved-plan.json$adrblock$navblock$cblock

## Your ticket
$TICKET$tspecblock$retryblock" "${prior_empty:-}"
    # S96: capture THIS attempt's worker output + files-written BEFORE $odir is
    # removed, so an eventual exhaustion can be classified. Signal only.
    cl_worker="$(cat "$odir/.worker.out" "$odir/.worker.err" 2>/dev/null || true)"
    cl_files="$(find "$odir/tests" "$odir/stubs" -type f 2>/dev/null || true)"
    # S98: EMPTY-WORKER branch — a worker that produced NOTHING (no file AND no
    # stdout/stderr) is the transient-CLI signal, NOT a bad suite. Detect it BEFORE
    # the "did it write tests" check, label it with the S96 `empty-worker-output`
    # category, bounded-retry with the file-first re-prompt, and — after a short cap
    # — escalate DISTINCTLY (never fold it into the generic "no usable tests" budget).
    if worker_produced_nothing "$odir"; then
      empty_tries=$((empty_tries + 1))
      emit_event ticket_worker_empty_output implement \
        "test-writer produced no output for $TICKET (attempt $awtry)" \
        "ticket=$TICKET" "phase=test-writer" "attempt=$awtry" "category=empty-worker-output"
      if [ "$empty_tries" -ge "$MAX_EMPTY_WORKER_TRIES" ]; then
        local ew_phrase; ew_phrase="$(impl_failure_category_phrase empty-worker-output)"
        emit_event ticket_test_writer_failed implement \
          "ticket $TICKET stopped: $ew_phrase" \
          "ticket=$TICKET" "phase=test-writer" "category=empty-worker-output" "attempts=$empty_tries"
        if [ -n "${MISSION_DIR:-}" ]; then
          printf '%s\tticket=%s\t%s: %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" "$TICKET" \
            "empty-worker-output" "$ew_phrase" \
            >>"$MISSION_DIR/implement-failure.log" 2>/dev/null || :
        fi
        rm -rf "$odir"
        die "the Test Writer worker produced no output $empty_tries times for $TICKET — likely a transient CLI failure, not a code problem — Stage stopped."
      fi
      # Arm the file-first re-prompt for the NEXT attempt, then retry from scratch.
      prior_empty=1
      rm -rf "$odir"
      continue
    fi
    prior_empty=""   # a non-empty attempt: keep the next prompt byte-for-byte normal
    if [ -d "$odir/tests" ] && [ -n "$(find "$odir/tests" -type f -print -quit 2>/dev/null)" ]; then
      local rc=0
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" impl-save-tests \
        --mission "$MISSION_ID" --ticket "$TICKET" --tests "$odir/tests" --stubs "$odir/stubs" || rc=$?
      if [ "$rc" -eq 0 ]; then saved=1; rm -rf "$odir"; break; fi
    fi
    rm -rf "$odir"
  done
  if [ "$saved" != 1 ]; then
    # S96 (SIGNAL ONLY — control flow + verdict unchanged): name the ROOT-CAUSE
    # category so the failure event and the stage-stop / awaiting-human text say
    # WHY, instead of the generic "no usable tests". The last attempt's red-gate
    # signal is the runner output; the worker output + files-written were retained
    # above. This ADDS a category; it never turns this rejection into an accept.
    local cl_runner=""; [ -f "$sigfile" ] && cl_runner="$(cat "$sigfile" 2>/dev/null || true)"
    local cl_cat cl_phrase
    cl_cat="$(classify_impl_failure "$cl_runner" "$cl_worker" "$cl_files")"
    cl_phrase="$(impl_failure_category_phrase "$cl_cat")"
    # Categorised failure event — the board renders the new "category" data field.
    emit_event ticket_test_writer_failed implement \
      "ticket $TICKET stopped: $cl_phrase" \
      "ticket=$TICKET" "phase=test-writer" "category=$cl_cat" "attempts=$MAX_WORKER_TRIES"
    # Durably record the phrase so implement_failure_tail surfaces it in the
    # stage-stop text the human sees (same additive channel as record_replay_failure).
    if [ -n "${MISSION_DIR:-}" ]; then
      printf '%s\tticket=%s\t%s: %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" "$TICKET" "$cl_cat" "$cl_phrase" \
        >>"$MISSION_DIR/implement-failure.log" 2>/dev/null || :
    fi
    die "the Test Writer worker produced no usable tests for $TICKET after $MAX_WORKER_TRIES attempt(s) — $cl_phrase — Stage stopped."
  fi

  # PHASE 2 — Implementer worker (no Test Writer context) → result.json →
  # impl-save-result. Its ONLY handoff is the tests now on disk.
  local tdir; tdir="$(ticket_dir "$TICKET")/tests"
  local iextra="## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/approved-plan.json
- $tdir   (the failing tests — your entire handoff from the Test Writer)$adrblock$navblock$cblock"
  # RESUME after a 5-attempt flag was answered: the captain's recorded note is
  # how to get this ticket unstuck. Feed it so the Implementer acts on it rather
  # than re-flagging the same blocker.
  [ -f "$MISSION_DIR/answers.json" ] && iextra="$iextra
- $MISSION_DIR/answers.json   (the captain's answer resolving the prior block on this ticket — treat it as DECIDED)"
  # SELF-HEAL feedback (BUG-029): when the full-suite gate found this ticket's
  # change REGRESSED an earlier ticket's locked contract, cmd_impl_advance re-runs
  # this ticket's Implementer with $LCARS_SELFHEAL_FEEDBACK carrying the harness-
  # authored reconcile instruction (which earlier test(s) broke + "do NOT touch the
  # locked contract"). It is the SAME single-line declarative feedback channel as
  # the red-gate signal / answers.json — never the implementation, never prior
  # reasoning. Each attempt is still a fresh cold worker.
  if [ -n "${LCARS_SELFHEAL_FEEDBACK:-}" ]; then
    iextra="$iextra

## FULL-SUITE RECONCILE FEEDBACK — your change regressed an earlier ticket (read this first)
Your previous implementation passed its OWN suite but, integrated with the rest
of the branch, it REGRESSED an earlier ticket's locked test. Reconcile your change
with the rest of the branch so EVERY suite (yours AND the regressed one) passes
again. You may ONLY edit production code — you must NOT alter any locked test or
contract. The harness's verdict (the regressed suite(s) + the command run):
$LCARS_SELFHEAL_FEEDBACK"
  fi
  iextra="$iextra

## Your ticket
$TICKET"
  tries=0
  # S98: fresh EMPTY-worker budget + re-prompt flag for the Implementer phase.
  empty_tries=0; prior_empty=""
  while [ "$tries" -lt "$MAX_WORKER_TRIES" ]; do
    tries=$((tries + 1))
    # Same cumulative-from-the-log numbering as Phase 1, for the implementer phase.
    local aitry; aitry=$(( $(event_count ticket_attempt "\"ticket\":\"$TICKET\".*\"phase\":\"implementer\"") + 1 ))
    emit_event ticket_attempt implement "implementer try $aitry for $TICKET" \
      "ticket=$TICKET" "phase=implementer" "attempt=$aitry"
    local odir; odir="$(mktemp -d)"
    spawn_worker implement-implementer "$STAGES_DIR/implement-implementer.md" repo-write "$odir" "$iextra" "${prior_empty:-}"
    # S98: EMPTY-WORKER branch (same shape as Phase 1) — a worker that produced
    # NOTHING (no result.json / no source AND no stdout/stderr) is the transient-CLI
    # signal, distinct from an Implementer whose result FAILED validation. Detect it
    # BEFORE the result.json check, label it, bounded-retry with the file-first
    # re-prompt, then escalate distinctly after the short cap.
    if worker_produced_nothing "$odir"; then
      empty_tries=$((empty_tries + 1))
      emit_event ticket_worker_empty_output implement \
        "implementer produced no output for $TICKET (attempt $aitry)" \
        "ticket=$TICKET" "phase=implementer" "attempt=$aitry" "category=empty-worker-output"
      if [ "$empty_tries" -ge "$MAX_EMPTY_WORKER_TRIES" ]; then
        local ew_phrase; ew_phrase="$(impl_failure_category_phrase empty-worker-output)"
        emit_event ticket_implementer_failed implement \
          "ticket $TICKET stopped: $ew_phrase" \
          "ticket=$TICKET" "phase=implementer" "category=empty-worker-output" "attempts=$empty_tries"
        if [ -n "${MISSION_DIR:-}" ]; then
          printf '%s\tticket=%s\t%s: %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" "$TICKET" \
            "empty-worker-output" "$ew_phrase" \
            >>"$MISSION_DIR/implement-failure.log" 2>/dev/null || :
        fi
        rm -rf "$odir"
        die "the Implementer worker produced no output $empty_tries times for $TICKET — likely a transient CLI failure, not a code problem — Stage stopped."
      fi
      prior_empty=1
      rm -rf "$odir"
      continue
    fi
    prior_empty=""
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

# === Test reconciliation (logged-bug Implement only) =======================
# BUG-058. A Mission-Log bug that CHANGES existing behaviour leaves a
# contradictory locked test behind: the bug's fix shrinks the X and writes a new
# test asserting the small X, but the PARENT mission's existing locked test still
# asserts the OLD value — and the immutable-tests guardrail FORBIDS the bug's
# Implementer from touching that locked parent test. The suite becomes self-
# contradictory and the fix can never go green. This step reconciles the parent's
# existing tests the bug's STATED change invalidates, BEFORE the bug's own Test
# Writer / Implementer run.
#
# SCOPE / GATING (tiny blast radius — keep it surgical):
#   • Runs ONLY for a LOGGED BUG: state.json type=="bug" AND parentMission set.
#     For a top-level mission's Implement it does NOTHING — that path (Test Writer
#     writes new fail-first tests + immutable-tests lock) is BYTE-FOR-BYTE
#     unchanged (this returns immediately, before any worker spawns).
#   • Reads ONLY the PARENT mission's ticket test suites under
#     .git/lcars/missions/<parentMission>/tickets/*/tests/. It never scans or
#     touches another mission's suites or the wider repo.
#   • ALWAYS-ON for logged bugs (no human flag); a clean reconciliation no-ops.
#
# An isolated COLD worker (same spawn_worker pattern as every other stage worker,
# engine-pinned) reads the bug's PRD (its intent + Out-of-Scope) and the parent's
# existing tests, then ADAPTS in place those whose assertions the bug's change
# contradicts (minimal assertion edits; remove a whole test only if fully
# obsolete), respecting the PRD's Out-of-Scope. It writes result.json with one of:
#   decision=reconciled  + a "changed" list → auto-apply: emit tests_reconciled,
#                          post a GitHub issue comment listing each test + why.
#   decision=noop         → nothing to reconcile → silent no-op.
#   decision=defer        + a plain-language "question" → raise the awaiting-human
#                          gate (pending.json + lcars:awaiting-human) and STOP.
# Defer is for ONLY: (a) reconciling would need to go BEYOND the parent suite, or
# (b) a genuine design ambiguity. NEVER for a routine, unambiguous reconciliation.
reconcile_tests() {
  # GATE: logged bug only (type==bug AND parentMission set). Anything else — a
  # top-level mission — returns immediately so that path is untouched.
  local mtype parent
  mtype="$(json_str "$STATE" type)"
  parent="$(json_str "$STATE" parentMission)"
  [ "$mtype" = "bug" ] && [ -n "$parent" ] || return 0

  # Resolve the PARENT mission's dir (sibling under .git/lcars/missions). Its test
  # suites live at tickets/*/tests/. If the parent has no such suites, there is
  # nothing to reconcile — a clean no-op.
  local parent_dir; parent_dir="$(dirname "$MISSION_DIR")/$parent"
  [ -d "$parent_dir/tickets" ] || return 0
  local tests_dirs; tests_dirs="$(find "$parent_dir/tickets" -type d -name tests 2>/dev/null | sort)"
  [ -n "$tests_dirs" ] || return 0

  # Idempotent: a resumed/re-entered Implement must not re-run reconciliation once
  # it has already reconciled or no-opped (re-editing locked parent tests would be
  # destructive). Skip if we have a terminal reconcile-tests outcome on file.
  if event_seen tests_reconciled implement "." || event_seen tests_reconcile_noop implement "."; then
    return 0
  fi
  # A pending defer from a prior pass means the gate is still open — leave it.
  if [ "$(json_raw "$STATE" awaitingHuman)" = "true" ] \
     && grep -q '"stage": "reconcile-tests"' "$MISSION_DIR/pending.json" 2>/dev/null; then
    emit_event tests_reconcile_blocked implement "test reconciliation still awaiting your answer — resolve it first"
    echo "IMPLEMENT: test reconciliation awaiting-human — resolve with \`lcars respond $MISSION_ID\` before continuing."
    exit 0
  fi

  # The bug's PRD — its intent + Out-of-Scope, the worker's primary input.
  local prd="$MISSION_DIR/prd.md"
  # Build the list of parent test dirs (by PATH only) for the worker prompt.
  local tblock="" d
  while IFS= read -r d; do
    [ -n "$d" ] && tblock="$tblock
- $d   (an existing locked test suite from the parent mission — adapt ONLY assertions this bug's change contradicts)"
  done <<EOF
$tests_dirs
EOF

  # Grant the worker READ+WRITE to the SHARED .git/lcars (so a hard-sandbox CLI can
  # both read the parent tests and edit them in place), CLI-agnostically — the
  # per-CLI translation is the adapter's job. Same mechanism implement-ticket uses.
  export LCARS_WORKER_INPUT_DIRS="$(dirname "$LCARS_CFG")"

  # The captain's recorded answer from a prior defer (lcars respond writes it), if
  # any — fed so a resumed reconciliation acts on it instead of re-asking.
  local ansblock=""
  [ -f "$MISSION_DIR/answers.json" ] && ansblock="
- $MISSION_DIR/answers.json   (the captain's answer resolving the prior reconciliation question — treat it as DECIDED)"

  local odir; odir="$(mktemp -d)"
  emit_event tests_reconcile_start implement "reconciling parent ($parent) tests the bug's change invalidates"
  spawn_worker reconcile-tests "$STAGES_DIR/reconcile-tests.md" repo-write "$odir" \
"## Read these artifacts (your ONLY inputs)
- $prd   (THIS bug's PRD — its intent AND its Out-of-Scope section, a hard constraint)$tblock$ansblock

## The parent mission
$parent (the mission this bug was logged against — adapt ONLY its test suites listed above, nothing else)"

  if [ ! -f "$odir/result.json" ]; then
    rm -rf "$odir"
    die "the test-reconciliation worker produced no result.json — Stage stopped."
  fi
  local result="$odir/result.json"
  local decision; decision="$(json_str "$result" decision)"

  case "$decision" in
    defer)
      # Beyond the parent suite OR a genuine design ambiguity — raise the awaiting-
      # human gate (same shape as validate-pause) and STOP. Make NO test edits.
      local q; q="$(json_str "$result" question)"
      [ -n "$q" ] || q="Test reconciliation needs your decision before this bug can proceed."
      local qf; qf="$(mktemp)"; printf '%s\n' "$q" >"$qf"
      write_pending "$qf" "reconcile-tests"
      rm -f "$qf"
      state_set_raw awaitingHuman true
      state_set_str pendingQuestion "$q"
      gh_relabel "lcars:implement lcars:awaiting-human" ""
      emit_event tests_reconcile_deferred implement "test reconciliation deferred to you: $q"
      notify_gate awaiting-human "Test reconciliation needs your call: $q"
      rm -rf "$odir"
      echo "IMPLEMENT: test reconciliation deferred — awaiting-human."
      echo "  $q"
      echo "  Answer with \`lcars respond $MISSION_ID\`."
      exit 0 ;;
    reconciled)
      # Auto-apply: the worker already edited the parent tests in place. Log WHAT it
      # changed to BOTH the UI (event) AND the GitHub issue (comment) — the audit
      # trail. Parse the "changed" array jq-free: pair each "file"/"change" line.
      # Pair each "file" with its "change", whether they sit on the SAME line
      # ({ "file":…, "change":… }) or on separate lines. Collect both key streams
      # in encounter order, then zip them — jq-free, same spirit as the rest.
      local lines; lines="$(awk '
        function val(s,    v) { v=s; sub(/.*:[[:space:]]*"/,"",v); sub(/".*/,"",v); return v }
        {
          line=$0
          while (match(line, /"file"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
            seg=substr(line, RSTART, RLENGTH); files[++nf]=val(seg)
            line=substr(line, RSTART+RLENGTH)
          }
          line=$0
          while (match(line, /"change"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
            seg=substr(line, RSTART, RLENGTH); changes[++nc]=val(seg)
            line=substr(line, RSTART+RLENGTH)
          }
        }
        END { for (i=1;i<=nf;i++) printf "%s: %s\n", files[i], (i<=nc?changes[i]:"") }
      ' "$result")"
      local n; n="$(printf '%s\n' "$lines" | grep -c .)"
      [ "$n" -gt 0 ] || n=0
      emit_event tests_reconciled implement "adapted $n test(s): $(printf '%s' "$lines" | tr '\n' '; ')" \
        "reconciled=$n"
      # Post a living GitHub issue comment listing each test changed + why (best-
      # effort, via the host adapter — the same path other stages comment through).
      local issue; issue="$(json_raw "$STATE" githubIssue)"
      case "$issue" in
        ''|null) : ;;
        *)
          local hdr items body
          hdr="$(printf 'LCARS test reconciliation (logged bug %s)\n\nAdapted %s existing test(s) from parent mission %s whose assertions this bug stated change invalidated:\n' "$MISSION_ID" "$n" "$parent")"
          items="$(printf '%s\n' "$lines" | sed '/^$/d; s/^/- /')"
          body="$hdr
$items"
          if ! host issue-comment "$issue" --body "$body"; then
            echo "  could not post the reconciliation comment to #$issue — record it by hand."
          fi
          ;;
      esac
      rm -rf "$odir"
      echo "IMPLEMENT: reconciled $n existing parent test(s)."
      while IFS= read -r l; do [ -n "$l" ] && echo "  • $l"; done <<EOF
$lines
EOF
      ;;
    *)
      # noop (or an unrecognised decision treated conservatively as noop): nothing
      # to reconcile. Record it so a re-entered Implement skips this step.
      emit_event tests_reconcile_noop implement "nothing to reconcile — the bug adds behaviour / contradicts no existing parent test"
      rm -rf "$odir"
      echo "IMPLEMENT: no existing parent tests to reconcile."
      ;;
  esac
  return 0
}

# --- subcommand: reconcile-tests (independently driveable + testable) -------
cmd_reconcile_tests() {
  locate_mission "$MISSION_ID"
  require_stage implement
  require_worker
  reconcile_tests
  exit 0
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

  # BUG-058: for a LOGGED BUG, reconcile the parent mission's existing tests the
  # bug's change invalidates BEFORE the bug's own Test Writer / Implementer run.
  # No-op (and untouched argv) for a top-level mission. May exit 0 here if it
  # raises an awaiting-human gate (a genuine design ambiguity / beyond-parent scope).
  reconcile_tests

  # Branch-CREATION contamination guard (BUG: concurrent-mission cross-birth).
  # Implement is the first stage to touch git; the mission branch may not exist
  # yet. Create it ONCE, up front, from the mission's RECORDED base under the
  # repo-global replay mutex — never lazily from the ambient $REPO_ROOT HEAD,
  # which under two concurrent missions in one clone is the OTHER mission's
  # branch. This guarantees make_ticket_worktree finds the branch (so every
  # ticket builds in a worktree off the correct base) and the in-tree fallback
  # never has to create it. Idempotent + best-effort; single-mission unaffected.
  ensure_mission_branch "$(json_str "$STATE" branch)"

  # --- S65: the live Implement-dashboard heartbeat ----------------------------
  # Start a bounded, best-effort ~60s ticker that re-renders + PATCHes the
  # Implement issue comment so elapsed/pace advance even during a long single
  # worker attempt. A trap on EXIT (any path: the impl-advance exit, a die, a
  # signal) KILLS the ticker cleanly so no orphan ticker ever outlives the run.
  # Entirely best-effort — a missing/failing gh never breaks or slows Implement.
  declare -F cm_heartbeat_start >/dev/null 2>&1 && cm_heartbeat_start
  trap 'declare -F cm_heartbeat_stop >/dev/null 2>&1 && cm_heartbeat_stop' EXIT INT TERM

  # For the wave_start instrumentation: totalWaves (distinct wave count) and a
  # per-wave ticket count, both derived jq-free from waves.json via parse_waves_table.
  local waves_file="$MISSION_DIR/waves.json"
  local total_waves; total_waves="$(parse_waves_table "$waves_file" 2>/dev/null | cut -f1 | sort -un | grep -c .)"

  local last_status="" last_wave=""
  while :; do
    # User-initiated pause (ADR-005). This is the BETWEEN-WAVE/TICKET safe
    # boundary: re-read paused at the TOP of the loop, before impl-status decides
    # the next wave. A paused Mission stops cleanly here — it does NOT advance to
    # Verify or start the next wave's tickets, and no worker is killed mid-step
    # (the prior wave's workers have already returned). It stays at `implement`
    # until `lcars resume` clears the flag.
    if [ "$(json_raw "$STATE" paused)" = "true" ]; then
      emit_event paused implement "paused by the captain — halted between waves"
      printf '⏸ paused at: implement  (paused by the captain — halted between waves)\n'
      printf 'The Mission is paused; no further tickets will run until you resume it.\n'
      printf 'Resume with `lcars resume %s`.\n' "$MISSION_ID"
      exit 0
    fi

    local st rc=0
    st="$(LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" impl-status --mission "$MISSION_ID" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$st" >&2
      die "impl-status failed — Implement cannot sequence the waves."
    fi

    case "$st" in
      *"IMPLEMENT: complete"*)
        # Every ticket is green — advance to Verify (it re-checks all waves).
        # BUG-020: the Implement→Verify handoff is driven from the DURABLE signal
        # ("IMPLEMENT: complete" = all tickets green / impl-status), NOT from
        # wait-ing a child that may have reparented. Before dispatching the
        # advance, STOP the comment heartbeat EXPLICITLY here (don't rely solely on
        # the EXIT trap firing only as the process exits) so its `sleep`/`gh` child
        # can never outlive this stage, reparent to init, and hold the driver's
        # command-substitution pipe open — which is what wedged this handoff for
        # ~19 min in the field. cm_heartbeat_stop is idempotent; the EXIT trap below
        # still runs as a belt-and-braces second reap.
        declare -F cm_heartbeat_stop >/dev/null 2>&1 && cm_heartbeat_stop
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
    # Session 41: regenerate the per-wave repo symbol map whenever the active wave
    # advances (including the first sight of wave 1). Fresh each wave so wave N's
    # implementers navigate wave N-1's committed symbols instead of cold-walking
    # the tree. Pure bash, token-free; the map carries the wave label so the
    # regeneration is observable. Keyed on cur_wave changing — the same boundary
    # the wave_start event fires on — but NOT gated on the dedup, so a re-entered
    # process still refreshes the map for the wave it resumes.
    if [ -n "$cur_wave" ] && [ "$cur_wave" != "$last_wave" ]; then
      generate_repo_map "$REPO_ROOT" "$MISSION_DIR/repo-map.md" "wave $cur_wave"
    fi
    last_wave="$cur_wave"

    # No-progress guard: if a full pass leaves impl-status reporting exactly the
    # same wave + pending set, we'd loop forever — stop loudly instead.
    [ "$st" != "$last_status" ] \
      || die "Implement made no progress on the current wave — Stage stopped (a ticket neither went green nor flagged)."
    last_status="$st"

    local pending; pending="$(printf '%s\n' "$st" | sed -n 's/.*Pending ticket(s) in wave [0-9]*: //p')"
    [ -n "$pending" ] || die "impl-status named an active wave but listed no pending tickets — Stage stopped."

    local branch; branch="$(json_str "$STATE" branch)"

    # --- INTRA-WAVE PARALLELISM (Session 37) -------------------------------
    # When a real mission branch exists we build this wave's pending tickets
    # CONCURRENTLY, each in its OWN per-ticket `git worktree` (detached at the
    # branch tip) so their file writes + test runs never collide on the shared
    # working tree. The adversarial Test-Writer→Implementer pair, the red gate,
    # and the immutable-test hash all run per ticket INSIDE its worktree,
    # unchanged. The fan-out is capped by $LCARS_MAX_PARALLEL via the ONE shared
    # run_capped helper. Without a branch (a branch-less / local-only mission)
    # there is no safe worktree, so we fall back to the ORIGINAL serial in-tree
    # loop — the only difference a concurrent wave makes is timing + isolation,
    # never the observable record.
    if [ -n "$branch" ] && "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
      # Each ticket records its build exit code to .build-rc (shared mission dir)
      # so the parent applies the SAME stop/flag rules deterministically AFTER the
      # wave — a fast green sibling can never mask a slow sibling's flag or
      # failure. A green ticket commits on its worktree's detached HEAD
      # (commit_ticket's worktree mode) and stashes the commit OBJECT in
      # .commit-sha; the parent cherry-picks those in plan order.
      local wt_base; wt_base="$MISSION_DIR/worktrees"
      local jobs; jobs="$(mktemp)"; : >"$jobs"
      for t in $pending; do
        # S102: also drop a stale .test-commit-sha so this FRESH build's Phase 1 writes
        # its own (a REUSE/rebuild build skips Phase 1 and never reaches here).
        rm -f "$(ticket_dir "$t")/.build-rc" "$(ticket_dir "$t")/.commit-sha" \
              "$(ticket_dir "$t")/.test-commit-sha" 2>/dev/null
        printf 'LCARS_TICKET_WT_BASE=%q LCARS_TICKET_BRANCH=%q bash %q implement-ticket --mission %q --ticket %q\n' \
          "$wt_base" "$branch" "$SELF" "$MISSION_ID" "$t" >>"$jobs"
      done
      # run_capped returns non-zero if any job exited non-zero; we IGNORE that and
      # read each ticket's recorded outcome below, in PLAN order, so the record is
      # deterministic regardless of finish order.
      LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" run_capped <"$jobs" || true
      rm -f "$jobs"

      # Apply the stop/flag rules in PLAN order ($pending is plan order). Serialize
      # every green ticket's commit onto the REAL mission branch by cherry-picking
      # its worktree commit — so the observable history is one commit per ticket,
      # with its summary, in plan order (NOT finish order).
      # CONFLICT-TRIGGERED SERIAL FALLBACK (Session 37 defect fix). Each ticket was
      # built BLIND off the FROZEN wave base, so two independent same-anchor edits
      # to a shared file cannot both cherry-pick — git can't auto-merge two
      # insertions at the same line, and the 2nd/3rd replay CONFLICTS. The old
      # serial in-tree path never hit this because each ticket built on the prior
      # ticket's already-applied tree. To restore that guarantee WITHOUT losing the
      # concurrency win for the common (disjoint-file) case, we replay every green
      # ticket's worktree commit in plan order; on a cherry-pick CONFLICT we REBUILD
      # just that ticket SERIALLY off the CURRENT mission tip (which now carries the
      # prior tickets' commits), reusing its locked tests — so its edits compose
      # exactly like the old serial path. Disjoint waves never conflict → stay fully
      # concurrent; a fully-overlapping wave degrades gracefully toward serial.
      #
      # hard_fail = a worker hard failure (no result); a flagged ticket (5-attempt
      # cap) instead set awaitingHuman in shared state and wrote NO .commit-sha, so
      # it simply has nothing to replay — escalate is decided from that flag AFTER
      # the loop, so a green sibling EARLIER in plan order still commits first (its
      # good work is never rolled back). Cleanup is UNCONDITIONAL below.
      local hard_fail=""
      for t in $pending; do
        local brc; brc="$(cat "$(ticket_dir "$t")/.build-rc" 2>/dev/null || echo 1)"
        if [ "$brc" != "0" ]; then hard_fail="$t"; break; fi
        # S102 (tests ride along): the ticket's LOCKED TEST was committed in Phase 1 on
        # the worktree's detached HEAD (its own commit, recorded to .test-commit-sha).
        # Cherry-pick it onto the real mission branch FIRST — BEFORE the impl commit —
        # so history reads test-commit → impl-commit and the test rides into the PR.
        # It is a NEW, unique co-located file, so it lands independently (no conflict);
        # a rare failure is best-effort (the impl replay + rebuild path still runs, and
        # the gates fall back to overlaying the mirror). On the REUSE/rebuild path Phase 1
        # was skipped so there is no fresh .test-commit-sha — correct, because the test
        # commit already landed here in this first pass, before the conflicting impl.
        local tsha; tsha="$(cat "$(ticket_dir "$t")/.test-commit-sha" 2>/dev/null || true)"
        if [ -n "$tsha" ]; then
          replay_ticket_commit "$branch" "$tsha" "$t" \
            || emit_event ticket_test_replay_conflict implement \
                 "ticket $t's locked-test commit did not cherry-pick cleanly; the gate will overlay the mirror" "ticket=$t"
        fi
        local sha; sha="$(cat "$(ticket_dir "$t")/.commit-sha" 2>/dev/null || true)"
        # No commit (a flagged ticket, or a green ticket with no file changes) →
        # nothing to replay.
        [ -n "$sha" ] || continue
        if replay_ticket_commit "$branch" "$sha" "$t"; then continue; fi
        # Cherry-pick CONFLICT — the same-anchor same-file case the frozen-base
        # build cannot compose. Rebuild THIS ticket serially on the CURRENT tip
        # (now carrying the prior tickets' commits), reusing its locked tests, so
        # its edits compose exactly like the old serial path.
        emit_event ticket_replay_conflict implement \
          "ticket $t conflicted on replay; rebuilding serially on the current tip" "ticket=$t"
        if rebuild_ticket_on_tip "$wt_base" "$branch" "$t"; then continue; fi
        # The rebuild did not cleanly replay. If it flagged the human (its
        # Implementer exhausted the cap even against the updated tree), the
        # awaitingHuman gate is set and the post-loop check routes it there — the
        # SAME recourse a normally-exhausted ticket gets, never a bare die. If it
        # instead hard-failed (no result, no flag), record a hard failure.
        if [ "$(json_raw "$STATE" awaitingHuman)" = "true" ]; then break; fi
        hard_fail="$t"; break
      done
      local escalate=""
      [ "$(json_raw "$STATE" awaitingHuman)" = "true" ] && escalate=1
      cleanup_ticket_worktrees "$wt_base"
      [ -z "$hard_fail" ] || die "implement-ticket $hard_fail failed — Stage stopped, no advance.$(implement_failure_tail)"
      [ -z "$escalate" ] || exit 0
    else
      # SERIAL FALLBACK (no mission branch): the original one-at-a-time in-tree
      # loop, byte-for-byte unchanged — a flagged ticket parks at the gate, a hard
      # failure stops the Stage non-zero.
      for t in $pending; do
        local irc=0
        LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" implement-ticket \
          --mission "$MISSION_ID" --ticket "$t" || irc=$?
        [ "$irc" -eq 0 ] || die "implement-ticket $t failed — Stage stopped, no advance.$(implement_failure_tail)"
        [ "$(json_raw "$STATE" awaitingHuman)" = "true" ] && exit 0
      done
    fi
  done
}

# --- provision a freshly-created worktree (Session 81) -----------------------
# Run a config-driven `worktreeSetupCommand` ONCE inside a just-created worktree,
# right after `git worktree add` and BEFORE any testCommand runs, so the red gate
# and the green (full-suite / post-commit) gates all evaluate in the SAME,
# dependency-complete environment. The command string is GENERIC — every ecosystem
# specific (npm ci / pnpm install / …) lives in that config value, NEVER here.
#
# Resolution mirrors resolve_test_cmd(): the env override ($LCARS_WORKTREE_SETUP_CMD)
# wins, then the repo config (worktreeSetupCommand). With NO command configured this
# is a safe NO-OP (rc 0, nothing created) so LCARS's own dependency-free dogfood stays
# green. The command runs EXACTLY ONCE with the worktree as CWD. Provisioning is
# BEST-EFFORT: a non-zero exit does NOT abort/throw the gate — it drops a concise
# `worktree_provision_failed` breadcrumb and returns the command's rc (the caller
# ignores it). It NEVER stages or git-adds anything (it only runs the command).
provision_worktree() { # worktree-path → 0 (no-op or success), else the command's rc
  local wt="$1" cmd rc=0
  if [ -n "${LCARS_WORKTREE_SETUP_CMD:-}" ]; then
    cmd="$LCARS_WORKTREE_SETUP_CMD"
  else
    [ -f "$LCARS_CFG" ] || return 0
    cmd="$(json_str "$LCARS_CFG" worktreeSetupCommand)"
  fi
  case "$cmd" in ''|null) return 0 ;; esac
  # Run ONCE with the worktree as CWD; capture combined output for the breadcrumb.
  local out; out="$( cd "$wt" && bash -c "$cmd" 2>&1 )" || rc=$?
  if [ "$rc" -ne 0 ]; then
    emit_event worktree_provision_failed implement \
      "worktreeSetupCommand exited $rc in $wt — provisioning is best-effort, the gate continues" \
      "rc=$rc"
    return "$rc"
  fi
  return 0
}

# --- per-ticket worktree lifecycle (Session 37) -----------------------------
# Create a detached worktree at the mission-branch tip for ONE ticket's build, so
# concurrent tickets never collide on the shared working tree. The branch itself
# stays checked out in the main tree; the worktree is DETACHED at its tip.
make_ticket_worktree() { # base-dir  branch  ticket → echoes the worktree path (empty ⇒ fall back to in-tree)
  local base="$1" branch="$2" t="$3"
  # No branch ref (a branch-less / local-only mission, or an unborn HEAD) ⇒ no
  # worktree; the caller falls back to the original in-tree path. Echo nothing.
  [ -n "$branch" ] && "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch" || return 0
  local wt="$base/$t"
  mkdir -p "$base"
  "$GIT_BIN" worktree remove --force "$wt" >/dev/null 2>&1 || :
  rm -rf "$wt"
  "$GIT_BIN" worktree add -q --detach "$wt" "$branch" >/dev/null 2>&1 || { rm -rf "$wt"; return 0; }
  # Session 81: provision the fresh worktree (dep install, etc.) ONCE, before any
  # gate's testCommand runs — covers BOTH the red gate's build worktree and the
  # full-suite gate. Best-effort: a failure drops a breadcrumb but never aborts the
  # worktree creation (the gate still runs inside it).
  provision_worktree "$wt" || :
  printf '%s' "$wt"
}

# --- REPO-GLOBAL replay mutex (BUG: concurrent-mission branch cross-contamination)
# `replay_ticket_commit` mutates the SHARED $REPO_ROOT working tree's HEAD
# (checkout the mission branch, then cherry-pick). Two missions running
# CONCURRENTLY in ONE clone each execute that in the SAME $REPO_ROOT, so
# mission B's `checkout` can interleave BETWEEN mission A's `checkout` and its
# `cherry-pick` — A's commit then lands on B's branch (confirmed live: 2 of
# M2's commits ended up on M1's branch). The checkout-if-needed + cherry-pick +
# conflict handling must therefore be ONE atomic critical section across ALL
# missions in the clone.
#
# The lock is a DIRECTORY under the SHARED git common dir (resolved via
# --git-common-dir, so a per-mission worktree resolves to the SAME path the main
# clone does → all missions contend for the SAME lock). `mkdir` is atomic on
# every POSIX fs, and crucially there is NO `flock` on macOS (darwin) — so this
# is a portable mkdir SPINLOCK, not flock. A holder writes its PID; a waiter
# spins until it can mkdir, reclaiming a STALE lock (dead-PID, or older than the
# timeout guard) so a crashed holder can never deadlock the pipeline. A trap
# releases it on every exit path, but only if we still own it.
REPLAY_LOCK_DIR=""                 # set while we hold the lock; "" = none held.
REPLAY_LOCK_STALE_SECS="${LCARS_REPLAY_LOCK_STALE_SECS:-300}"

# Path of the repo-global replay lock dir under the SHARED git common dir.
replay_lock_path() {
  local common; common="$( cd "$REPO_ROOT" 2>/dev/null && "$GIT_BIN" rev-parse --git-common-dir 2>/dev/null )"
  [ -n "$common" ] || common="$REPO_ROOT/.git"
  # --git-common-dir may be relative (".git") — anchor it at $REPO_ROOT.
  case "$common" in /*) : ;; *) common="$REPO_ROOT/$common" ;; esac
  mkdir -p "$common/lcars" 2>/dev/null || :
  printf '%s' "$common/lcars/replay.lock"
}

# Acquire the repo-global replay lock (BLOCKS — a true mutex). Spins on the
# atomic mkdir; reclaims a stale lock (dead PID or older than the timeout) so a
# crashed holder never deadlocks. Arms a trap to release on exit. Always 0.
acquire_replay_lock() {
  local lock; lock="$(replay_lock_path)"
  local pidf="$lock/pid" spins=0
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s' "$$" >"$pidf" 2>/dev/null || :
      REPLAY_LOCK_DIR="$lock"
      # BUG-021: cmd_implement arms a `trap … cm_heartbeat_stop … EXIT INT TERM`
      # for the Implement comment-heartbeat, then calls replay_ticket_commit (which
      # acquires THIS lock) in its own process. A bare `trap 'release_replay_lock'`
      # here would CLOBBER that heartbeat trap, so any later flag/error/escalation
      # EXIT path would release the lock but NEVER reap the heartbeat → an orphaned
      # `while … gh issue comment …; sleep 60; done` loop (PPID=1) keeps POSTing
      # forever. So the lock's exit trap also reaps the heartbeat. cm_heartbeat_stop
      # is idempotent and a no-op when no heartbeat is running, so this is safe at
      # every acquire_replay_lock site (the explicit clean-path stop still fires too).
      trap 'release_replay_lock; declare -F cm_heartbeat_stop >/dev/null 2>&1 && cm_heartbeat_stop' EXIT INT TERM
      return 0
    fi
    # Held — reclaim if the holder is dead OR the lock is older than the guard.
    local owner=""; [ -f "$pidf" ] && owner="$(cat "$pidf" 2>/dev/null)"
    local stale=0
    if ! pid_alive "$owner"; then stale=1; fi
    if [ "$stale" = 0 ]; then
      # Live-PID guard against a hung holder: reclaim once the dir outlives the
      # timeout. `find -mmin` keeps it bash-3.2 / macOS portable (no GNU stat).
      if [ -n "$(find "$lock" -prune -mmin +"$(( REPLAY_LOCK_STALE_SECS / 60 + 1 ))" 2>/dev/null)" ]; then
        stale=1
      fi
    fi
    if [ "$stale" = 1 ]; then
      rm -rf "$lock" 2>/dev/null || :
      continue
    fi
    sleep 0.05
    spins=$((spins + 1))
  done
}

# Release the lock IFF we still own it (our PID in the pid file). Idempotent;
# trap-safe — a process that never acquired it deletes nothing.
release_replay_lock() {
  [ -n "$REPLAY_LOCK_DIR" ] || return 0
  local owner=""; [ -f "$REPLAY_LOCK_DIR/pid" ] && owner="$(cat "$REPLAY_LOCK_DIR/pid" 2>/dev/null)"
  if [ "$owner" = "$$" ]; then
    rm -rf "$REPLAY_LOCK_DIR" 2>/dev/null || :
  fi
  REPLAY_LOCK_DIR=""
}

# Cherry-pick a green ticket's worktree commit onto the real mission branch in the
# main working tree, SERIALLY (called in plan order). Preserves the exact commit
# message (cherry-pick keeps it) → one commit per ticket, summary intact, in order.
#
# The HEAD-mutating critical section (checkout-if-needed + cherry-pick + the
# conflict/abort handling) runs under the REPO-GLOBAL replay mutex so concurrent
# missions in one clone never interleave a checkout between this mission's
# checkout and its cherry-pick — each pick is GUARANTEED to land on its own
# branch regardless of which mission held HEAD last. Single-mission runs take an
# uncontended lock (near-zero overhead; behaviour unchanged).
# Set by _replay_ticket_commit_locked on a cherry-pick failure to the captured
# reason (conflicted paths + git error). Read by callers/record_replay_failure so
# a TERMINAL replay failure records WHY (BUG-051). Reset on entry to each replay.
REPLAY_FAIL_REASON=""

# Durably record a TERMINAL replay/rebuild cherry-pick failure (BUG-051): append a
# timestamped, ticket-scoped line (with the git error + conflicted paths) to the
# per-mission implement-failure.log AND emit a ticket_replay_failed event carrying
# a short reason. This is purely additive instrumentation — it changes no control
# flow / outcome; it only ensures the cause is not silently discarded. Called ONLY
# at the genuine terminal-failure point (not the expected conflict→rebuild path).
record_replay_failure() { # ticket  reason
  local t="$1" reason="$2"
  [ -n "${MISSION_DIR:-}" ] && printf '%s\tticket=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" "$t" "$reason" \
    >>"$MISSION_DIR/implement-failure.log" 2>/dev/null || :
  emit_event ticket_replay_failed implement \
    "ticket $t cherry-pick failed: $reason" "ticket=$t"
}

# Tail of the per-mission implement-failure.log, formatted to ride a die message
# (BUG-051) — so a hard stage stop names WHY rather than a bare generic line. Empty
# string when there's nothing logged (the die message is then unchanged).
implement_failure_tail() {
  [ -n "${MISSION_DIR:-}" ] && [ -s "$MISSION_DIR/implement-failure.log" ] || return 0
  local tail; tail="$(tail -n 3 "$MISSION_DIR/implement-failure.log" 2>/dev/null)"
  [ -n "$tail" ] && printf ' reason: %s' "$(printf '%s' "$tail" | tr '\n' ' ')"
}

replay_ticket_commit() { # branch  sha  ticket
  local branch="$1" sha="$2" t="$3" rc=0
  REPLAY_FAIL_REASON=""
  acquire_replay_lock
  _replay_ticket_commit_locked "$branch" "$sha" "$t" || rc=$?
  release_replay_lock
  return "$rc"
}

# The atomic critical section — runs ONLY while the replay mutex is held. The
# checkout-if-needed is INSIDE the lock so the cherry-pick lands on $branch no
# matter which branch HEAD was left on by another mission's just-released replay.
_replay_ticket_commit_locked() { # branch  sha  ticket
  local branch="$1" sha="$2" t="$3"
  # Ensure the main tree is on the mission branch. Under concurrency HEAD may be
  # on ANOTHER mission's branch (it just released the lock), so this re-checkout
  # is load-bearing, not the old single-mission "it already is" assumption.
  local cur; cur="$( cd "$REPO_ROOT" && "$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null )"
  if [ "$cur" != "$branch" ]; then
    if "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
      # Capture the checkout's OWN stderr (do not discard it) so a failure names
      # its real cause instead of degrading to the generic "cherry-pick failed".
      # The dominant failure here is git REFUSING to move a branch that is checked
      # out in ANOTHER worktree ("fatal: '<b>' is already checked out at '<path>'")
      # — deliberate git behaviour, NOT a mergeable condition. Surface WHICH
      # worktree holds it + the remedy so the operator frees that tree rather than
      # chasing a phantom merge conflict. The fix itself is already built and green.
      local co_err
      if ! co_err="$( cd "$REPO_ROOT" && "$GIT_BIN" checkout "$branch" 2>&1 >/dev/null )"; then
        local held_wt
        held_wt="$( cd "$REPO_ROOT" && "$GIT_BIN" worktree list --porcelain 2>/dev/null \
          | awk -v b="branch refs/heads/$branch" '
              /^worktree /{p=substr($0,10)}
              $0==b{print p; exit}' )"
        if [ -n "$held_wt" ]; then
          REPLAY_FAIL_REASON="branch $branch is checked out in another git worktree ($held_wt) — git will not let the fix land there while it is held. The ticket's fix is built and green; free that worktree (remove it, or check it out detached) and re-run implement."
        else
          REPLAY_FAIL_REASON="could not check out branch $branch in the main tree to land the fix${co_err:+; git: $(printf '%s' "$co_err" | tr '\n' ' ')}"
        fi
        return 1
      fi
    fi
  fi
  # Capture the cherry-pick's own STDERR (the git error) and, while the conflict
  # state still exists (BEFORE --abort wipes it), the list of conflicted paths —
  # so a genuine replay failure records WHY instead of discarding it (BUG-051).
  local cp_err
  cp_err="$( cd "$REPO_ROOT" && "$GIT_BIN" cherry-pick --allow-empty "$sha" 2>&1 >/dev/null )" || {
    local cp_conflicts
    cp_conflicts="$( cd "$REPO_ROOT" && "$GIT_BIN" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ' )"
    REPLAY_FAIL_REASON="cherry-pick of $sha failed${cp_conflicts:+; conflicted paths: ${cp_conflicts% }}${cp_err:+; git: $(printf '%s' "$cp_err" | tr '\n' ' ')}"
    ( cd "$REPO_ROOT" && "$GIT_BIN" cherry-pick --abort >/dev/null 2>&1 ) || :
    # `cherry-pick --abort` restores only TRACKED state. Any UNTRACKED residue the
    # just-failed pick left at one of THIS commit's paths — a NEW file the pick
    # staged then could not fully apply, or a path it refused to overwrite ("would
    # be overwritten by merge", so --abort is a no-op) — survives. The serial
    # rebuild then produces a clean commit ADDING that same path, whose re-apply
    # git refuses ("untracked working tree files would be overwritten") → the wave
    # hard-fails instead of degrading to serial. Clear ONLY this commit's own paths
    # that are now untracked, so the rebuilt commit re-applies — never the captain's
    # unrelated untracked files (we touch nothing outside $sha's changed paths).
    ( cd "$REPO_ROOT" && "$GIT_BIN" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null \
        | while IFS= read -r p; do
            [ -n "$p" ] || continue
            [ -n "$("$GIT_BIN" ls-files --others --exclude-standard -- "$p" 2>/dev/null)" ] \
              && rm -f -- "$p"
          done ) || :
    return 1
  }
  return 0
}

# Rebuild ONE ticket serially when its concurrent (frozen-base) commit could not
# cherry-pick — the same-file conflict fix. The ticket's locked tests are already
# on disk (tickets/<id>/tests + .sha256), so only the Implementer re-runs, and it
# re-runs inside a FRESH worktree that make_ticket_worktree cuts off the CURRENT
# mission-branch tip (which now carries the prior tickets' commits) — so its edits
# compose on top of them exactly like the old serial in-tree path, with no merge.
# On green it writes a NEW .commit-sha (a commit whose parent IS the current tip),
# which we cherry-pick cleanly. Returns 0 on a clean replay; non-zero if the
# rebuild flagged the human (awaitingHuman set), produced an EMPTY diff (BUG-016 —
# it failed to reproduce a change we KNOW was non-empty, so it escalates to the
# same awaiting-human gate rather than silently dropping the ticket), or hard-failed
# (caller routes the escalation / hard-fail after the unconditional worktree cleanup).
rebuild_ticket_on_tip() { # base-dir  branch  ticket
  local base="$1" branch="$2" t="$3"
  # Drop the stale concurrent outcome so we read the rebuild's fresh result.
  rm -f "$(ticket_dir "$t")/.build-rc" "$(ticket_dir "$t")/.commit-sha" 2>/dev/null
  local irc=0
  LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" \
  LCARS_TICKET_WT_BASE="$base" LCARS_TICKET_BRANCH="$branch" LCARS_REUSE_TESTS=1 \
    bash "$SELF" implement-ticket --mission "$MISSION_ID" --ticket "$t" || irc=$?
  # A flag (5-attempt cap) set awaitingHuman in shared state — let the caller route
  # it to the gate. A hard failure (no result) returns non-zero with no .commit-sha.
  [ "$irc" -eq 0 ] || return 1
  local sha; sha="$(cat "$(ticket_dir "$t")/.commit-sha" 2>/dev/null || true)"
  # No commit from the rebuild (BUG-016). We ONLY reach a rebuild AFTER the
  # concurrent (frozen-base) build produced a REAL commit that CONFLICTED on replay
  # — so the ticket's change is genuinely non-empty (a truly empty ticket had no
  # .commit-sha to cherry-pick and never entered this path). An empty-diff rebuild
  # therefore means the Implementer did NOT reproduce that change on the updated tip
  # — its locked tests still demand code that did not land. Silently `return 0`-ing
  # here DROPS the ticket: its work never reaches the branch and the Mission either
  # dead-ends at the BUG-013 full-suite gate or advances missing the ticket, with no
  # recourse. Route it to the SAME awaiting-human gate a cap-exhausted ticket gets
  # (pending question + label), so the caller's post-loop check parks it for `lcars
  # respond` — never a silent drop, never a bare die. Return non-zero so the caller
  # routes via the awaitingHuman flag (the prior green siblings already committed).
  if [ -z "$sha" ]; then
    local q; q="$(mktemp)"
    printf 'Ticket %s could not be recomposed on the current tip: after a same-file replay conflict its serial rebuild produced NO file changes, so the change it made in the concurrent build never landed. Its locked tests still require that code — the ticket needs a human.\n' \
      "$t" >"$q"
    write_pending "$q" "implement"
    state_set_raw awaitingHuman true
    state_set_str pendingQuestion "Ticket $t could not be recomposed after a same-file replay conflict (empty rebuild) — needs a human."
    gh_relabel "lcars:awaiting-human" ""
    rm -f "$q"
    emit_event ticket_rebuild_empty implement \
      "ticket $t rebuilt empty on the tip after a replay conflict; escalating to awaiting-human" "ticket=$t"
    return 1
  fi
  # The serial rebuild produced a fresh commit ON the current tip — its cherry-pick
  # should land cleanly. If it STILL fails (BUG-053: green-via-serial-rebuild then a
  # cherry-pick that vanishes), this is a TERMINAL failure — durably record WHY so
  # the cause does not disappear (BUG-051), then return non-zero unchanged.
  local rrc=0
  replay_ticket_commit "$branch" "$sha" "$t" || rrc=$?
  if [ "$rrc" -ne 0 ]; then
    record_replay_failure "$t" \
      "${REPLAY_FAIL_REASON:-rebuilt ticket $t failed to cherry-pick onto the tip ($sha)}"
    return "$rrc"
  fi
  return 0
}

# Remove every per-ticket worktree for this wave and prune git's bookkeeping, so
# nothing leaks into the captain's `git worktree list` or working tree.
cleanup_ticket_worktrees() { # base-dir
  local base="$1" d
  [ -d "$base" ] || return 0
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    "$GIT_BIN" worktree remove --force "${d%/}" >/dev/null 2>&1 || rm -rf "${d%/}"
  done
  "$GIT_BIN" worktree prune >/dev/null 2>&1 || :
  rm -rf "$base" 2>/dev/null || :
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

# --- the PR merge-state poll: "merged" iff the host says state MERGED OR
# mergedAt is a non-null value. gh absent/failing → echoes nothing → not merged
# (best-effort: a transient failure just keeps the Mission in review, never a
# false Done). Identify the PR by the recorded number, else the branch.
drive_pr_merged() { # → 0 if merged, 1 otherwise
  local num branch sel_args=() out st merged
  num="$(json_raw "$STATE" prNumber)"
  branch="$(json_str "$STATE" branch)"
  case "$num" in
    ''|null) sel_args=(--head "$branch") ;;
    *)       sel_args=(--number "$num") ;;
  esac
  out="$(host pr-view "${sel_args[@]}" 2>/dev/null)" || return 1
  st="$(printf '%s\n' "$out" | sed -n 's/^state	//p' | head -1)"
  merged="$(printf '%s\n' "$out" | sed -n 's/^mergedAt	//p' | head -1)"
  [ "$st" = "MERGED" ] && return 0
  case "$merged" in ''|null|'""') return 1 ;; *) return 0 ;; esac
}

# --- mark a Mission Done after a merge detected on the board's side (the driver
# saw the PR merged on GitHub, or directly). Mirrors approve's done transition.
drive_mark_done() {
  gh_relabel "lcars:done" "lcars:verify lcars:awaiting-human"
  set_stage "done"
  state_set_str review "merged"
  emit_event stage_done verify "PR merged — Mission shipped"
}

# --- S75 Verify: auto-open the PR, then poll for a merge ----------------------
# Three paths:
#   • no PR yet      → open it (cmd_open_pr subprocess), record prUrl, fire ONE
#                      notification, halt "in review". Sets nothing in
#                      $DRIVE_VERIFY_DONE → the driver STOPS.
#   • PR open, merged (here or on GitHub) → mark Done. Sets $DRIVE_VERIFY_DONE=1
#                      so the driver continues (next pass: stage=done → terminal).
#   • PR open, unmerged → halt "in review" WITHOUT re-notifying (the ping fires
#                      ONCE, when the PR is first opened). Driver STOPS.
drive_verify() { # accumulated-summary
  local summary="$1"
  local pr; pr="$(json_str "$STATE" prUrl)"

  # BUG-026: a Mission-Log bug child (parentMission set) FOLDS its fix onto the
  # PARENT Mission's branch — the parent's PR carries it; the bug has NO PR of its
  # own. So at Verify it must NOT open a per-bug PR (and must NEVER hit the degraded
  # "PR-open degraded; needs attention" gate that fires when no PR can be opened).
  # Skip the entire reconcile + PR-open machinery; resolve-logs drives the fold and
  # raises the parent's single consolidated re-verify gate. The child simply parks
  # at verify with no PR affordance and no degraded gate.
  local parent; parent="$(json_str "$STATE" parentMission)"
  if [ -n "$parent" ] && [ "$parent" != "null" ]; then
    emit_event gate verify "bug fix folds onto parent $parent — no per-bug PR"
    drive_print_summary "$summary"
    printf 'verify       ◇  bug fix folds onto parent %s — no per-bug PR (parent carries it)\n' "$parent"
    printf '⏹ stopped at: verify  (folds onto the parent — accept via the parent'"'"'s re-verify gate)\n'
    return 0
  fi

  # S76 reconcile gate: ONLY when no PR is open yet (once a PR is open, the human/
  # GitHub owns conflicts — never re-reconcile). Before opening the PR, check
  # whether the base moved ahead; if so, merge it in an isolated worktree and
  # re-test the combined state, self-healing to green via Mission Log(s). The gate
  # runs as a subprocess (same pattern as open-pr) so it shares one code path and
  # its worker/log/resolve spawns are scoped. Exit codes: 0 = proceed (not ahead
  # or clean+green), 10 = reconciling (halt this pass), 20 = escalated (halt, no PR).
  case "$pr" in
    http*|*/pull/*) : ;;   # a PR exists — skip the reconcile gate entirely.
    *)
      local rcout rrc=0
      rcout="$(LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" reconcile --mission "$MISSION_ID" 2>&1)" || rrc=$?
      case "$rrc" in
        10) # reconciling — self-heal dispatched; halt this pass, resume next pass.
            mirror_comments || true
            drive_print_summary "$summary"
            printf 'verify       ◐  reconciling with %s — re-verifying the merged branch\n' "$(json_str "$STATE" base)"
            printf '%s\n' "$rcout"
            printf '⏹ stopped at: verify  (reconciling with the updated base — self-heal in flight)\n'
            printf 'It will re-merge & re-verify on the next `lcars run %s` pass.\n' "$MISSION_ID"
            return 0 ;;
        20) # escalated — awaiting-human; reconcile_escalate already fired the gate.
            mirror_comments || true
            drive_print_summary "$summary"
            printf '%s\n' "$rcout"
            drive_halt_awaiting verify
            return 0 ;;
        *)  : ;;   # 0 (or any other) → proceed to today's open-PR path below.
      esac ;;
  esac

  case "$pr" in
    http*|*/pull/*)
      # A PR exists — has it merged (here or on GitHub)?
      if drive_pr_merged; then
        drive_mark_done
        drive_line_done_inline="$(printf 'verify       ✓  PR merged — Mission shipped')"
        printf '%s\n' "$drive_line_done_inline"
        DRIVE_VERIFY_DONE=1
        return 0
      fi
      # Still open — in review. Halt, but do NOT re-ping (one ping at open time).
      emit_event gate verify "in review — PR open"
      mirror_comments || true
      drive_print_summary "$summary"
      drive_halt_in_review "$pr"
      return 0 ;;
  esac

  # No PR yet — open it (reusing the cmd_open_pr subprocess so the open path is
  # one code path). On a hard open failure, surface it and STOP at verify.
  printf '%-12s ▶  opening PR…\n' "verify"
  local out rc=0
  out="$(LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" open-pr --mission "$MISSION_ID" 2>&1)" || rc=$?
  local pr2; pr2="$(json_str "$STATE" prUrl)"
  case "$pr2" in
    http*|*/pull/*) : ;;
    *) # PR-open degraded (no gh / unauthed / create failed). This is STILL a
       # human gate — the Mission is parked at verify needing attention — so we
       # must fire EXACTLY ONE walk-away notification (never a false Done), and
       # only once: a guard flag makes a later retry not re-ping. The driver
       # STOPS here.
       emit_event gate verify "parked at verify — PR open degraded; needs attention"
       drive_print_summary "$summary"
       printf '⏹ stopped at: verify  (could not open the PR)\n'
       printf '%s\n' "$out"
       printf 'Fix the cause (push/auth/gh), then `lcars run %s` to retry the open.\n' "$MISSION_ID"
       if [ "$(json_str "$STATE" verifyDegradedNotified)" != "1" ]; then
         notify_gate verify "Mission parked at verify — review needed (PR could not be opened automatically)"
         state_set_str verifyDegradedNotified "1"
       fi
       return 0 ;;
  esac

  # PR opened — fire the ONE notification and halt "in review".
  emit_event gate verify "PR opened — review & merge"
  mirror_comments || true
  drive_print_summary "$summary"
  printf 'verify       ✓  PR opened — %s\n' "$pr2"
  local title; title="$(json_str "$STATE" title)"; title="${title:-$MISSION_ID}"
  notify_gate verify "PR open — review & merge: $pr2"
  drive_halt_in_review "$pr2"
  return 0
}

# --- the in-review halt banner (no notification here; the ping fired once at
# open time). Shows the PR link + the two moves: merge (approve) / send-back.
drive_halt_in_review() { # pr-url
  printf '⏹ stopped at: verify  (in review — PR open)\n'
  printf 'PR is open for review: %s\n' "$1"
  printf 'Review & merge, then:\n'
  printf '  lcars approve %s    — merge the PR (ship it)\n' "$MISSION_ID"
  printf '  lcars feedback %s   — send back with feedback (closes the PR)\n' "$MISSION_ID"
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

drive_halt_paused() { # stage
  printf '⏸ paused at: %s  (paused by the captain — halted at a safe boundary)\n' "$1"
  printf 'The Mission is paused; no Stage will advance until you resume it.\n'
  printf 'Resume with `lcars resume %s`.\n' "$MISSION_ID"
}

drive_halt_align() {
  printf '⏹ stopped at: align  (interactive Align re-grill required)\n'
  printf 'This Mission was sent back from Verify (feedback.md is present). Align is a\n'
  printf 'human grilling session, not automatable: re-grill it in your session and\n'
  printf 'rewrite the PRD, then it auto-advances from Research.\n'
}

# === Per-mission driver lock (BUG-A: single-instance `drive`) ===============
# The viewscreen Start button (and pause→resume) could fire `run drive` for the
# SAME mission more than once. Without a guard, N drivers raced the stage advance
# and EACH spawned cold workers — state corruption + real credit waste. So the
# driver is single-instance PER MISSION: only one live `cmd_drive` may advance a
# given mission at a time.
#
# The lock is a DIRECTORY ($MISSION_DIR/driver.lock) — `mkdir` is atomic on every
# POSIX fs, so two near-simultaneous drivers can't both win. The winner writes
# its PID into driver.lock/pid; the loser checks whether that PID is alive:
#   • alive   → a real driver is already advancing this mission → no-op exit 0.
#   • dead    → a STALE lock from a crashed driver → reclaim it and proceed
#               (never deadlock after a crash).
# A trap releases the lock on EXIT/INT/TERM, but ONLY if we still own it (our PID
# in the pid file) — so a process that found a live lock and bailed never deletes
# the real owner's lock. The single `--step` path and the auto loop both go
# through cmd_drive, so both respect the lock. `resume` re-execs `drive`, so it is
# idempotent for free: a resume while a driver is live is a clean no-op.
DRIVER_LOCK_DIR=""        # set once we hold the lock; "" = we hold none.

# Is PID $1 a live process? Portable (kill -0). Empty/non-numeric → not alive.
pid_alive() { # pid
  local p="$1"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null
}

# === Stage watchdog (BUG-020) ===============================================
# A bounded guard so a Mission can NEVER sit SILENTLY frozen between/within
# stages: run a command with a hard wall-clock timeout, killing it (and a brief
# grace then SIGKILL) if it overruns. macOS/bash-3.2 safe — no `timeout(1)`
# dependency. Returns the command's exit code, or 124 if it timed out (the GNU
# `timeout` convention) so the caller can distinguish a wedge from a real error.
# The default budget is generous ($LCARS_STAGE_TIMEOUT, seconds; 0/unset disables
# the watchdog entirely so nothing here can shorten a legitimately long stage).
run_with_watchdog() { # secs  cmd...
  local secs="$1"; shift
  case "$secs" in ''|*[!0-9]*) secs=0 ;; esac
  if [ "$secs" -le 0 ] 2>/dev/null; then
    "$@"
    return $?
  fi
  # Run the command in the background as its OWN session/process-group leader, so
  # a timeout can reap the WHOLE descendant tree — not just direct children — even
  # when nested workers reparent/orphan (BUG-048). macOS has no `setsid(1)`, so we
  # use perl's POSIX::setsid (same trick the daemon launcher uses): the perl `exec`
  # replaces itself with the command, preserving the backgrounded pid, and after
  # setsid that pid is its own group leader (PGID == PID). setsid() fails if the
  # caller is already a group leader; backgrounding with `&` normally makes the
  # child a non-leader so it succeeds, but we guard in eval so a no-op setsid never
  # aborts the exec. A sibling poll races it: bash-3.2 lacks `wait -n`, so we poll
  # the command pid at a coarse interval up to the budget.
  perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- "$@" &
  local cmd_pid=$!
  local waited=0 step=1
  while [ "$waited" -lt "$secs" ]; do
    pid_alive "$cmd_pid" || break
    sleep "$step" 2>/dev/null || break
    waited=$((waited + step))
  done
  if pid_alive "$cmd_pid"; then
    # Overran the budget — the wedge BUG-020 is about. Kill the entire PROCESS
    # GROUP (negative pid == kill the group led by cmd_pid), which reaps the whole
    # descendant tree regardless of reparenting and works on macOS. Brief grace,
    # then SIGKILL the group, then report the timeout sentinel.
    kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null || true
    sleep 1 2>/dev/null || true
    kill -KILL -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null || true
    wait "$cmd_pid" 2>/dev/null || true
    return 124
  fi
  wait "$cmd_pid"
  return $?
}

# === Cold-worker hang watchdog (BUG-076) ====================================
# A `copilot -p` (or any cold) worker can hang MID-TURN: 0% CPU, no output, and
# it NEVER returns — so the spawn_worker retry loop (which only retries when a
# worker RETURNS a failure) is wedged forever. run_with_watchdog above is a
# wall-clock cap and cannot tell a SLOW-but-working worker from a HUNG one; a
# generous wall-clock budget either kills legitimately long work early or lets a
# hang sit. This guard is CPU- AND output-AWARE: it kills a worker ONLY when it
# is BOTH idle (group CPU ~0%) AND silent (output files not growing) for a
# SUSTAINED window, and leaves a worker that is using CPU or still producing
# output completely alone. macOS/bash-3.2 safe — no `timeout(1)`, no GNU ps flags.

# Sum the CPU% across an entire process GROUP (pgid == the session leader's pid).
# Portable `ps` (BSD/macOS + Linux): list pid,pcpu,pgid for all procs and add up
# %CPU of those whose pgid matches. Prints an integer (floored). Empty/no match
# ⇒ 0. Used to decide "is this worker tree doing ANY work right now?".
_pgid_cpu_sum() { # pgid → integer cpu% (stdout)
  local pgid="$1"
  case "$pgid" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  ps -axo pid=,pcpu=,pgid= 2>/dev/null | awk -v g="$pgid" '
    $3 == g { sum += $2 }
    END { printf "%d", (sum + 0) }'
}

# Print "<size> <mtime>" for a file (portable: BSD `stat -f`, GNU `stat -c`),
# or "0 0" when the file is absent. Used to detect output GROWTH between polls —
# either the byte size changed or the mtime advanced counts as progress.
_file_size_mtime() { # path → "<size> <mtime>" (stdout)
  local f="$1"
  [ -f "$f" ] || { printf '0 0'; return 0; }
  stat -f '%z %m' "$f" 2>/dev/null && return 0   # BSD / macOS
  stat -c '%s %Y' "$f" 2>/dev/null && return 0   # GNU / Linux
  printf '0 0'
}

# Run a cold-worker command HANG-GUARDED. Launches it as its OWN process-group
# leader (perl POSIX::setsid + exec — REUSE the BUG-048 pattern in
# run_with_watchdog), so the whole descendant tree can be group-killed. While it
# runs, poll every LCARS_WORKER_HANG_POLL seconds: read the group's CPU% and the
# combined size+mtime of $outdir/.worker.out + .worker.err. Whenever CPU exceeds
# the threshold OR the output has grown, RESET the stagnation timer (the worker
# is alive and working). If CPU stays at/below the threshold AND the output is
# unchanged for a SUSTAINED LCARS_WORKER_HANG_SECS, declare it HUNG: group-kill
# it (TERM then KILL, falling back to the bare pid like run_with_watchdog) and
# return the HUNG sentinel 137, which the spawn_worker retry loop counts as a
# FAILED try (so it retries within MAX_WORKER_TRIES; escalates only if exhausted).
# The HUNG sentinel is 137 (128+SIGKILL) — distinct from a normal worker rc.
# LCARS_WORKER_HANG_SECS=0 (or unset/non-numeric ⇒ default) disables the guard:
# the command runs unguarded and its real rc round-trips.
# Default window = 900s (15 min): comprehension-heavy cold workers on modular
# repos are API-bound (near-0 LOCAL CPU) and buffer output to end-of-turn, so a
# legitimate 4-8 min Test-Writer/Implementer turn reads as "idle+silent" and the
# old 240s window false-killed it; a genuinely wedged worker is still caught
# within 15 min and the retry loop bounds the waste. Env-overridable.
run_worker_hang_guarded() { # outdir  cmd...
  local outdir="$1"; shift
  local hang_secs="${LCARS_WORKER_HANG_SECS:-900}"
  case "$hang_secs" in ''|*[!0-9]*) hang_secs=900 ;; esac
  # Disabled → run inline, unguarded; the command's real rc round-trips.
  if [ "$hang_secs" -le 0 ] 2>/dev/null; then
    "$@"
    return $?
  fi
  local poll="${LCARS_WORKER_HANG_POLL:-15}"
  case "$poll" in ''|*[!0-9]*) poll=15 ;; esac
  [ "$poll" -ge 1 ] 2>/dev/null || poll=1
  local cpu_min="${LCARS_WORKER_HANG_CPU_MIN:-2}"
  case "$cpu_min" in ''|*[!0-9]*) cpu_min=2 ;; esac

  # Launch as its own session/group leader (PGID == PID) so a group-kill reaps
  # the whole tree even when nested workers reparent/orphan. Same perl trick as
  # run_with_watchdog; the perl `exec` preserves the backgrounded pid.
  perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- "$@" &
  local cmd_pid=$!

  local out_a="$outdir/.worker.out" out_b="$outdir/.worker.err"
  local last_sig=""; last_sig="$(_file_size_mtime "$out_a")|$(_file_size_mtime "$out_b")"
  local stagnant=0
  while pid_alive "$cmd_pid"; do
    sleep "$poll" 2>/dev/null || break
    pid_alive "$cmd_pid" || break
    local cpu sig
    cpu="$(_pgid_cpu_sum "$cmd_pid")"
    sig="$(_file_size_mtime "$out_a")|$(_file_size_mtime "$out_b")"
    # Progress = the worker is burning CPU OR its output grew → reset the timer.
    if [ "$cpu" -gt "$cpu_min" ] 2>/dev/null || [ "$sig" != "$last_sig" ]; then
      stagnant=0
      last_sig="$sig"
      continue
    fi
    # Idle AND silent this interval — accumulate stagnation.
    stagnant=$((stagnant + poll))
    if [ "$stagnant" -ge "$hang_secs" ]; then
      # HUNG: group-kill the whole tree, then return the distinct sentinel so the
      # caller's retry loop counts this as a failed try.
      kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 1 2>/dev/null || true
      kill -KILL -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null || true
      wait "$cmd_pid" 2>/dev/null || true
      return 137   # HUNG sentinel (128+SIGKILL) — see header
    fi
  done
  wait "$cmd_pid"
  return $?
}

# Try to take the per-mission driver lock. Prints nothing; returns:
#   0  → lock acquired (DRIVER_LOCK_DIR set, trap armed, our pid written)
#   1  → a LIVE driver already holds it (caller must no-op exit 0)
acquire_driver_lock() {
  local lock="$MISSION_DIR/driver.lock" pidf
  pidf="$lock/pid"
  # Two tries: the second covers reclaiming a stale lock between the failed mkdir
  # and the alive-check (the only window another driver could clear it in).
  local try
  for try in 1 2; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s' "$$" >"$pidf"
      DRIVER_LOCK_DIR="$lock"
      trap 'release_driver_lock' EXIT INT TERM
      return 0
    fi
    # Lock dir exists — is its owner alive?
    local owner=""; [ -f "$pidf" ] && owner="$(cat "$pidf" 2>/dev/null)"
    if pid_alive "$owner"; then
      return 1                    # a real driver holds it → caller no-ops.
    fi
    # Stale (dead/empty owner): reclaim and retry the atomic mkdir.
    rm -rf "$lock" 2>/dev/null
  done
  return 1
}

# Release the lock IFF we still own it (our pid in the pid file). Idempotent;
# safe in a trap. A driver that found a live lock and bailed never deletes it.
release_driver_lock() {
  [ -n "$DRIVER_LOCK_DIR" ] || return 0
  local owner=""; [ -f "$DRIVER_LOCK_DIR/pid" ] && owner="$(cat "$DRIVER_LOCK_DIR/pid" 2>/dev/null)"
  if [ "$owner" = "$$" ]; then
    rm -rf "$DRIVER_LOCK_DIR" 2>/dev/null
  fi
  DRIVER_LOCK_DIR=""
}

cmd_drive() {
  locate_mission "$MISSION_ID"

  # Single-instance guard (BUG-A). If a live driver already holds this mission's
  # lock, this invocation is a clean no-op — never a second concurrent driver.
  if ! acquire_driver_lock; then
    printf '%s  already running\n%s\n' "$MISSION_ID" "$SEP"
    printf '⏹ a driver is already advancing this Mission (single-instance) — nothing to do.\n'
    printf '  Watch it on the board, or `lcars pause %s` to halt it at the next boundary.\n' "$MISSION_ID"
    return 0
  fi

  local mode="auto"; [ "$STEP" = 1 ] && mode="step"
  printf '%s  %s-advance\n%s\n' "$MISSION_ID" "$mode" "$SEP"

  local summary=""
  while :; do
    # Re-read the live state each pass (a Stage subprocess just rewrote it).
    local stage awaiting paused
    stage="$(json_str "$STATE" stage)"
    awaiting="$(json_raw "$STATE" awaitingHuman)"
    paused="$(json_raw "$STATE" paused)"

    # User-initiated pause (ADR-005). This is the BETWEEN-STAGES safe boundary:
    # checked BEFORE running anything, structured like the halt blocks below. A
    # paused Mission stops cleanly here and does NOT advance — no Stage subprocess
    # is spawned, no worker is killed mid-step (none is running). It stays put
    # until `lcars resume` clears the flag.
    if [ "$paused" = "true" ]; then
      emit_event paused "$stage" "paused by the captain — halted at the $stage boundary"
      mirror_comments || true
      drive_print_summary "$summary"; drive_halt_paused "$stage"; return 0
    fi

    # ADR-004 issue-comment mirror (S65 living per-stage model) — harness-driven,
    # best-effort. Re-renders each STAGE's living comment (create-then-edit, keyed
    # by stage in comments.json) from the on-disk truth the prior pass produced,
    # and pings any newly-raised human gate as a NEW comment. mirror_comments is
    # idempotent (the comment-id map is the dedup truth) and NEVER fails the run
    # (gh missing/unauthed/failing → no-op). The gate emits just below get their
    # own mirror on the halt paths so the gate ping lands before we stop.
    mirror_comments || true

    # Halt conditions, checked BEFORE running anything. Each emits a `gate` event
    # to the Mission log (the halt block + notify hook below are unchanged).
    if [ "$awaiting" = "true" ]; then
      emit_event gate "$stage" "awaiting your answer"
      mirror_comments || true
      drive_print_summary "$summary"; drive_halt_awaiting "$stage"; return 0
    fi
    case "$stage" in
      verify) # S75: Verify auto-opens the PR, then parks "in review — PR open"
              # and polls for a merge (here or on GitHub) → Done. drive_verify
              # owns the open/poll/halt; it returns 0 to STOP the driver (in
              # review or a hard open failure) or non-empty $DRIVE_VERIFY_DONE to
              # signal "merged → continue the loop" (the next pass sees stage=done).
              DRIVE_VERIFY_DONE=""
              drive_verify "$summary"
              [ -n "$DRIVE_VERIFY_DONE" ] && continue
              return 0 ;;
      done)   emit_event gate done "Mission shipped — the PR is merged"
              mirror_comments || true
              drive_print_summary "$summary"
              printf '⏹ stopped at: done  (Mission shipped — the PR is merged)\n'; return 0 ;;
      align)  if [ -f "$MISSION_DIR/feedback.md" ]; then
                emit_event gate align "interactive Align re-grill required"
                mirror_comments || true
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

    # BUG-020 watchdog: run the Stage subprocess under a bounded wall-clock guard
    # so a wedged stage (e.g. a leaked Implement heartbeat holding the pipe open)
    # can never freeze the driver SILENTLY between stages. We capture the stage's
    # output via a FILE (not a `$(…)` pipe) so the watchdog can background the
    # subprocess and reap it on overrun — a backgrounded child that inherits a
    # command-substitution pipe is exactly what kept the driver blocked. On a
    # timeout (rc 124) we escalate to awaiting-human with an actionable message
    # rather than hang forever. The budget is $LCARS_STAGE_TIMEOUT seconds
    # (0/unset = no watchdog, never shortening a legitimately long stage).
    local out rc=0 stage_timeout="${LCARS_STAGE_TIMEOUT:-0}"
    local outf; outf="$(mktemp)"
    run_with_watchdog "$stage_timeout" \
      env LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" \
        bash "$SELF" "$action" --mission "$MISSION_ID" >"$outf" 2>&1 || rc=$?
    out="$(cat "$outf")"; rm -f "$outf"

    if [ "$rc" -eq 124 ]; then
      # The stage overran the watchdog — a wedge, not a clean result. Park it as
      # awaiting-human (never a silent freeze): record an actionable question and
      # stop cleanly. Re-read state first in case the stage DID transition just
      # before the kill (then we fall through to the normal handling below).
      local wd_stage wd_await
      wd_stage="$(json_str "$STATE" stage)"; wd_await="$(json_raw "$STATE" awaitingHuman)"
      if [ "$wd_stage" = "$stage" ] && [ "$wd_await" != "true" ]; then
        local wdq="The $action stage exceeded the ${stage_timeout}s watchdog and was stopped to avoid a silent freeze (see BUG-020). Re-run \`lcars run $MISSION_ID\` to resume; if it recurs, inspect the worker/heartbeat for a leaked child."
        local wq; wq="$(mktemp)"; printf '%s\n' "$wdq" >"$wq"
        write_pending "$wq" "$stage"; rm -f "$wq"
        state_set_raw awaitingHuman true
        state_set_str pendingQuestion "$wdq"
        gh_relabel "lcars:awaiting-human" ""
        emit_event error "$stage" "$action timed out under the stage watchdog (${stage_timeout}s) — escalated to awaiting-human"
        drive_print_summary "$summary"
        printf '⏱ stopped: %s timed out under the watchdog — flagged the human (resolve with `lcars respond %s`).\n' "$action" "$MISSION_ID"
        printf '%s\n' "$out"
        return 0
      fi
    fi

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
        if [ "$new_stage" = "verify" ]; then
          # Stepping INTO verify auto-opens the PR (same path as auto mode), then
          # parks in review. drive_verify prints its own summary + banner.
          DRIVE_VERIFY_DONE=""
          drive_verify "$summary"
        else
          drive_print_summary "$summary"
          printf '⏹ stepped one Stage → now at: %s\n' "$new_stage"
          printf 'Run `lcars run %s` to continue (or add `--step` for one more).\n' "$MISSION_ID"
        fi
        return 0
      fi
      continue
    fi

    # Nothing advanced and no gate was raised → a hard Stage error. Carry the
    # cause: the tail of the stage subprocess output ($out) — including any die
    # reason — so the board event itself names WHY (BUG-051), not a bare "failed".
    local err_tail; err_tail="$(printf '%s' "$out" | tr '\n' ' ')"
    err_tail="${err_tail: -200}"
    emit_event error "$stage" "$stage failed${err_tail:+: $err_tail}"
    drive_print_summary "$summary"
    printf '⏹ stopped: %s failed\n' "$stage"
    printf '%s\n' "$out"
    return "${rc:-1}"
  done
}

# --- dispatch --------------------------------------------------------------
SUB="${1:-}"; [ $# -gt 0 ] && shift

MISSION_ID=""; QFILE=""; RESPONSES=""; PLAN=""; VERDICT=""; TICKET=""; TESTS=""; STUBS=""; RESULT=""; STEP=0
EV_TYPE=""; EV_STAGE=""; EV_DETAIL=""; MANIFESTS=""; POSARG=""; SURFACE=""
RC_BRANCH=""; RC_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --step)        STEP=1; shift ;;
    --surface)     SURFACE="${2:-}"; shift 2 ;;
    --surface=*)   SURFACE="${1#--surface=}"; shift ;;
    --mission)     MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*)   MISSION_ID="${1#--mission=}"; shift ;;
    --questions)   QFILE="${2:-}"; shift 2 ;;
    --questions=*) QFILE="${1#--questions=}"; shift ;;
    --responses)   RESPONSES="${2:-}"; shift 2 ;;
    --responses=*) RESPONSES="${1#--responses=}"; shift ;;
    --plan)        PLAN="${2:-}"; shift 2 ;;
    --plan=*)      PLAN="${1#--plan=}"; shift ;;
    --manifests)   MANIFESTS="${2:-}"; shift 2 ;;
    --manifests=*) MANIFESTS="${1#--manifests=}"; shift ;;
    --verdict)     VERDICT="${2:-}"; shift 2 ;;
    --verdict=*)   VERDICT="${1#--verdict=}"; shift ;;
    --ticket)      TICKET="${2:-}"; shift 2 ;;
    --ticket=*)    TICKET="${1#--ticket=}"; shift ;;
    --branch)      RC_BRANCH="${2:-}"; shift 2 ;;
    --branch=*)    RC_BRANCH="${1#--branch=}"; shift ;;
    --sha)         RC_SHA="${2:-}"; shift 2 ;;
    --sha=*)       RC_SHA="${1#--sha=}"; shift ;;
    --tests)       TESTS="${2:-}"; shift 2 ;;
    --tests=*)     TESTS="${1#--tests=}"; shift ;;
    --stubs)       STUBS="${2:-}"; shift 2 ;;
    --stubs=*)     STUBS="${1#--stubs=}"; shift ;;
    --result)      RESULT="${2:-}"; shift 2 ;;
    --result=*)    RESULT="${1#--result=}"; shift ;;
    --type)        EV_TYPE="${2:-}"; shift 2 ;;
    --type=*)      EV_TYPE="${1#--type=}"; shift ;;
    --stage)       EV_STAGE="${2:-}"; shift 2 ;;
    --stage=*)     EV_STAGE="${1#--stage=}"; shift ;;
    --detail)      EV_DETAIL="${2:-}"; shift 2 ;;
    --detail=*)    EV_DETAIL="${1#--detail=}"; shift ;;
    # A single bare positional (the stage key / role for resolve-stage-model /
    # spawn-stage). Only these subcommands consume it; others still reject extras.
    -*)            die "unknown argument: $1" ;;
    *)             if [ -z "$POSARG" ]; then POSARG="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

case "$SUB" in
  gate|save|validate-pause|validate-advance|plan-save|review-save|schedule|impl-save-tests|impl-save-result|impl-status|impl-advance|verify-summary|open-pr|research|validate|estimate|plan|plan-review|implement|implement-ticket|reconcile-tests|drive|emit-event)
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
  open-pr)          cmd_open_pr ;;
  reconcile)        cmd_reconcile ;;
  # Stage drivers (spawn cold workers, then persist via the subcommands above).
  research)         cmd_research ;;
  validate)         cmd_validate ;;
  # End-of-Align estimator (session 59): writes estimate.json (two criticality
  # scores + per-stage model map) that S58's resolve_stage_model consumes. Driven
  # by lcars-file at the end of Align; OPTIONAL — a failure never blocks filing.
  estimate)         cmd_estimate ;;
  plan)             cmd_plan ;;
  plan-review)      cmd_plan_review ;;
  implement)        cmd_implement ;;
  implement-ticket) cmd_implement_ticket ;;
  # BUG-058: reconcile the parent mission's existing tests a logged bug's change
  # invalidates, before the bug's own Test Writer/Implementer run. No-op on a
  # top-level mission. Independently driveable + testable; cmd_implement also
  # calls reconcile_tests() directly up front.
  reconcile-tests)  cmd_reconcile_tests ;;
  # One research agent, spawned as a capped fan-out job (run_capped). Stateless:
  # its ONLY inputs are $LCARS_RA_DIR (where to write) and $LCARS_RA_Q (the one
  # question). No --mission — research_agent_worker reaches no mission artifacts.
  # The cold-worker bin/model arrive via the inherited $LCARS_WORKER_BIN/_MODEL
  # env (set by the parent cmd_research); resolve them SILENTLY here (no log line —
  # the parent already printed it once) so spawn_worker sees a real binary.
  research-agent-job) resolve_worker_bin; resolve_worker_model
                      research_agent_worker "${LCARS_RA_DIR:-}" "${LCARS_RA_Q:-}" ;;
  # Auto-advance driver — sequences the per-Stage advances above (token-free).
  drive)            cmd_drive ;;
  # Repo-level context resolver (no mission) — prints the durable context source
  # path, generating the one-time pack lazily. Reused by lcars-file's Align flow.
  context-source)   cmd_context_source ;;
  # Per-wave repo symbol map (no LLM — pure bash). Regenerated by cmd_implement at
  # each wave; exposed here so it is independently driveable + testable.
  repo-map)         cmd_repo_map ;;
  # Cold-worker bin/model resolution (no LLM, no mission) — prints the resolution
  # log line + a machine-readable summary. The test surface for resolve_worker.
  resolve-worker)   cmd_resolve_worker ;;
  # Per-stage model resolution (no LLM, no real mission state) — prints
  # `STAGE-MODEL key=<k> model=<flag|->`. The test surface for resolve_stage_model.
  resolve-stage-model) [ -n "$POSARG" ] || die "usage: run.sh resolve-stage-model [--mission <id>] <stage-key>"
                       cmd_resolve_stage_model "$POSARG" ;;
  # CLI-aware mission cost (session 60) — reads --mission's estimate.json +
  # pricing.json + the active CLI, prints the canonical cost JSON block. Pure (no
  # LLM); the test surface for cost_compute.
  cost)             [ -n "$MISSION_ID" ] || die "usage: run.sh cost --mission <id>"
                    cmd_cost ;;
  # Captain-facing estimate rendering (session 61) — reads --mission's
  # estimate.json + the active CLI, prints the requested --surface (issue|cli)
  # block. Absent estimate.json ⇒ no output + non-zero (lcars-file degradation).
  render-estimate)  [ -n "$MISSION_ID" ] || die "usage: run.sh render-estimate --mission <id> --surface issue|cli"
                    cmd_render_estimate ;;
  # Drive the real worker_spawn chokepoint for one env-role through the resolved
  # worker bin (a stub in tests) so the spawned argv (incl. per-stage --model) is
  # observable end-to-end. The spawn-path test surface.
  spawn-stage)         [ -n "$POSARG" ] || die "usage: run.sh spawn-stage [--mission <id>] <role>"
                       cmd_spawn_stage "$POSARG" ;;
  # Test hook: emit one event line to the Mission event log (jq-free helper).
  emit-event)       locate_mission "$MISSION_ID"; emit_event "$EV_TYPE" "$EV_STAGE" "$EV_DETAIL" ;;
  # ADR-004: mirror not-yet-posted surfaced events from events.jsonl onto the
  # Mission's issue as ordered comments, idempotently. The driver calls this at
  # each loop pass; it is also the standalone test/maintenance entry point.
  # Best-effort: mirror_comments never fails the caller, so force exit 0.
  mirror-comments)  locate_mission "$MISSION_ID"; mirror_comments || true ;;
  # Test hook for the repo-global replay mutex (concurrent-mission branch
  # cross-contamination fix): drive replay_ticket_commit for ONE commit onto a
  # named branch, under the lock. --branch <b> --sha <sha> [--ticket <t>]. Exits
  # non-zero iff the replay failed (e.g. cherry-pick conflict).
  replay-commit)
    locate_mission "$MISSION_ID"
    [ -n "$RC_BRANCH" ] || die "usage: run.sh replay-commit --mission <id> --branch <b> --sha <sha>"
    [ -n "$RC_SHA" ]    || die "usage: run.sh replay-commit --mission <id> --branch <b> --sha <sha>"
    replay_ticket_commit "$RC_BRANCH" "$RC_SHA" "${TICKET:-t-x}" ;;
  # BUG-051 test hook: drive replay_ticket_commit and, on a TERMINAL cherry-pick
  # failure, run the SAME durable-recording path rebuild_ticket_on_tip's terminal
  # branch uses (record_replay_failure → implement-failure.log + ticket_replay_failed
  # event with the captured reason). Asserts the cause is captured, not discarded.
  # --branch <b> --sha <sha> [--ticket <t>]. Exits non-zero iff the replay failed.
  replay-commit-record)
    locate_mission "$MISSION_ID"
    [ -n "$RC_BRANCH" ] || die "usage: run.sh replay-commit-record --mission <id> --branch <b> --sha <sha>"
    [ -n "$RC_SHA" ]    || die "usage: run.sh replay-commit-record --mission <id> --branch <b> --sha <sha>"
    _rcr=0
    replay_ticket_commit "$RC_BRANCH" "$RC_SHA" "${TICKET:-t-x}" || _rcr=$?
    if [ "$_rcr" -ne 0 ]; then
      record_replay_failure "${TICKET:-t-x}" \
        "${REPLAY_FAIL_REASON:-rebuilt ticket failed to cherry-pick onto the tip ($RC_SHA)}"
    fi
    exit "$_rcr" ;;
  # Test hook for the branch-CREATION contamination fix: create the mission's
  # branch from its RECORDED base under the replay mutex (idempotent), exactly as
  # cmd_implement does up front. --branch <b> overrides state.json's branch (so a
  # test can drive both missions' branches from one mission dir). Always exits 0.
  ensure-mission-branch)
    locate_mission "$MISSION_ID"
    ensure_mission_branch "${RC_BRANCH:-$(json_str "$STATE" branch)}" ;;
  # Session 81 test hook: exercise make_ticket_worktree's provisioning. Cuts a fresh
  # detached worktree (the SHARED path for the red gate's build worktree AND the
  # full-suite gate) and — unlike the real flow — does NOT clean it up, so the test
  # can inspect the provisioned tree. Echoes `WT=<path>` (empty on fall-back). The
  # branch defaults to state.json's (override with --branch); ticket defaults to "all".
  provision-worktree-test)
    locate_mission "$MISSION_ID"
    __pwt="$(make_ticket_worktree "$MISSION_DIR/wt-test" "${RC_BRANCH:-$(json_str "$STATE" branch)}" "${TICKET:-all}")"
    printf 'WT=%s\n' "$__pwt"
    exit 0 ;;
  # Session 65 test/maintenance hook: start the Implement comment heartbeat,
  # report its ticker pid, let it run its bounded ticks ($LCARS_COMMENT_HEARTBEAT_TICKS),
  # then stop it cleanly (no orphan). Exercises the heartbeat lifecycle (start /
  # tick / kill) deterministically. Best-effort: always exits 0.
  comment-heartbeat-test)
    locate_mission "$MISSION_ID"
    cm_heartbeat_start
    printf 'TICK_PID=%s\n' "${CM_HEARTBEAT_PID:-}"
    # Wait for the bounded ticker to finish on its own, then ensure it's reaped.
    [ -n "${CM_HEARTBEAT_PID:-}" ] && wait "$CM_HEARTBEAT_PID" 2>/dev/null
    cm_heartbeat_stop
    exit 0 ;;
  # BUG-021 test hook: reproduce the Implement FLAG/ERROR/ESCALATION exit path that
  # leaked the comment-heartbeat. cmd_implement arms the heartbeat-reap EXIT trap,
  # then (inside the wave loop) calls replay_ticket_commit → acquire_replay_lock,
  # whose trap USED to CLOBBER the heartbeat trap; an escalation `exit 0` afterwards
  # would then release the lock but NEVER reap the heartbeat → an orphaned ticker.
  # This hook arms the SAME heartbeat trap cmd_implement does, acquires the replay
  # lock (the clobber point), then exits via a NON-clean escalation path WITHOUT an
  # explicit cm_heartbeat_stop — exactly the leak path. It prints the ticker pid so
  # the test asserts no orphan ticker (or its `sleep` child) survives the exit.
  heartbeat-reap-test)
    locate_mission "$MISSION_ID"
    cm_heartbeat_start
    # The exact trap cmd_implement arms right after cm_heartbeat_start.
    trap 'declare -F cm_heartbeat_stop >/dev/null 2>&1 && cm_heartbeat_stop' EXIT INT TERM
    printf 'TICK_PID=%s\n' "${CM_HEARTBEAT_PID:-}"
    # Take the repo-global replay lock — the operation that re-arms the EXIT trap and
    # (pre-fix) clobbered the heartbeat reap. This is the SAME call replay_ticket_commit
    # makes inside the wave loop. We do NOT call cm_heartbeat_stop after it: this stands
    # in for a flag/error/escalation branch that early-exits the stage.
    acquire_replay_lock
    release_replay_lock
    # Escalation early-exit: NO explicit cm_heartbeat_stop. With the fix, the lock's
    # composite EXIT trap still reaps the ticker; without it, the ticker orphans.
    exit 0 ;;
  # S83 test hook: run the un-runnable-ENVIRONMENT detector on stdin and exit with
  # its return code (0 = env failure detected, 1 = none). Inert for every real
  # subcommand — reachable only by this explicit token from the test suite, so the
  # pure detector's pattern coverage can be unit-tested directly.
  red-gate-env-detect-test)
    _rg_in="$(cat)"
    if red_gate_env_failure "$_rg_in"; then exit 0; else exit 1; fi
    ;;
  # BUG-024 test hook: run the compile/LOAD-failure detector on stdin and exit with
  # its return code (0 = compile/load failure detected, 1 = none). Inert for every
  # real subcommand — reachable only by this explicit token from the test suite, so
  # the detector's module-resolution pattern coverage can be unit-tested directly.
  red-gate-compile-detect-test)
    _rg_in="$(cat)"
    if red_gate_compile_failure "$_rg_in"; then exit 0; else exit 1; fi
    ;;
  # S96 test hook: run the module-RESOLUTION detector on stdin and exit with its
  # return code (0 = resolution failure detected, 1 = none). Inert for every real
  # subcommand — reachable only by this token, so the table-driven detector's
  # pattern coverage is unit-testable directly (regression: byte-equivalent).
  red-gate-resolution-detect-test)
    _rg_in="$(cat)"
    if red_gate_resolution_failure "$_rg_in"; then exit 0; else exit 1; fi
    ;;
  # S96 test hook: classify a stopped Implement attempt into ONE root-cause
  # category and print it. The runner output is read from stdin; the worker's
  # output and the newline-separated files-written list are passed via env
  # ($LCARS_CLASSIFY_WORKER_OUT / $LCARS_CLASSIFY_FILES, both default empty) so the
  # precedence of classify_impl_failure can be driven directly, offline + free.
  # Inert for every real subcommand — reachable only by this explicit token.
  classify-impl-failure-test)
    _ci_runner="$(cat)"
    classify_impl_failure "$_ci_runner" "${LCARS_CLASSIFY_WORKER_OUT:-}" "${LCARS_CLASSIFY_FILES:-}"
    printf '\n'
    exit 0 ;;
  # S98 test hook: run the pure EMPTY-worker detector on a pre-populated OUTDIR
  # ($LCARS_TEST_OUTDIR) and exit with its return code (0 = produced NOTHING, 1 =
  # produced something — a real file OR any stdout/stderr). Detection reads ONLY the
  # outdir contents (files + .worker.out/.worker.err), never the CLI name, so this
  # hook proves the transient-CLI signal is engine-agnostic. Inert for every real
  # subcommand — reachable only by this explicit token from the test suite.
  worker-empty-detect-test)
    if worker_produced_nothing "${LCARS_TEST_OUTDIR:-}"; then exit 0; else exit 1; fi
    ;;
  # S99 test hook: pure self-smoke verdict — runner output on stdin, rc via env.
  self-smoke-verdict-test)
    _ss_in="$(cat)"
    self_smoke_verdict "${LCARS_SS_RC:-0}" "$_ss_in"
    printf '\n'; exit 0 ;;
  # S99 test hook: portable hard timeout — runs $LCARS_HT_CMD under $LCARS_HT_SECS,
  # prints RC=<rc> (124 = timed out+killed). Offline, free.
  run-hard-timeout-test)
    _ht_out="$(mktemp)"; _ht_rc=0
    run_with_hard_timeout "${LCARS_HT_SECS:-120}" "$_ht_out" bash -c "${LCARS_HT_CMD:-true}" || _ht_rc=$?
    rm -f "$_ht_out"; printf 'RC=%s\n' "$_ht_rc"; exit 0 ;;
  # S99 test hook: zero-tests detector on stdin (rc 0 = zero tests).
  suite-zero-tests-test)
    _zt_in="$(cat)"; if suite_collected_zero_tests "$_zt_in"; then exit 0; else exit 1; fi ;;
  # S97 test hook: run the reconcile RETEST env-blocked verdict on stdin and exit
  # with its return code (0 = env-blocked / the runner could not start, 1 = a genuine
  # red). Reads the captured retest output on stdin (written to a temp <id>.log so the
  # dir-capture path is exercised). Inert for every real subcommand — reachable only
  # by this explicit token, so the pure verdict is unit-testable offline + free.
  reconcile-retest-env-blocked-test)
    _re_in="$(cat)"
    _re_tmp="$(mktemp -d)"
    printf '%s\n' "$_re_in" >"$_re_tmp/t-001.log"
    if reconcile_retest_env_blocked "$_re_tmp"; then rm -rf "$_re_tmp"; exit 0; else rm -rf "$_re_tmp"; exit 1; fi
    ;;
  # S87 test hook: echo ticket_target_package for a ticket (optionally against a
  # given root, the positional). Inert for every real subcommand — reachable only
  # by this token from the test suite, so the manifest→package resolver can be
  # unit-tested directly without driving a whole Implement attempt.
  ticket-target-package-test)
    locate_mission "$MISSION_ID"
    ticket_target_package "$TICKET" "${POSARG:-$REPO_ROOT}"
    printf '\n'
    exit 0 ;;
  # S87 test hook: drive the REAL post_commit_gate (branch mode) for one ticket,
  # without spawning any worker. The mission's state.json branch must point at a
  # real branch whose tip is the COMMITTED state to verify. Captures the gate's
  # signal to $POST_COMMIT_SIGNAL and prints its rc, so the in-package monorepo
  # staging can be exercised on a real worktree cut at that branch tip.
  post-commit-gate-test)
    locate_mission "$MISSION_ID"
    __pcg_sig="${LCARS_PC_SIGNAL_OUT:-$MISSION_DIR/pc-test-signal.txt}"; rm -f "$__pcg_sig"
    __pcg_rc=0
    POST_COMMIT_SIGNAL="$__pcg_sig" post_commit_gate "$TICKET" || __pcg_rc=$?
    printf 'PCRC=%s\n' "$__pcg_rc"
    exit 0 ;;
  # S84 test hook: drive the REAL full_suite_gate over the mission's scheduled
  # tickets (parsed from waves.json, exactly as cmd_impl_advance does) WITHOUT the
  # self-heal wrapper — so the gate's env-vs-regression classification can be
  # exercised on a missing runner without spawning any (billable) Implementer
  # worker. Captures the gate's signal to $LCARS_FS_SIGNAL_OUT and prints its rc.
  full-suite-gate-test)
    locate_mission "$MISSION_ID"
    __fsg_ordered=""
    if [ -f "$MISSION_DIR/waves.json" ]; then
      while IFS=$'\t' read -r __fsg_w __fsg_id; do
        [ -n "$__fsg_id" ] || continue
        __fsg_ordered="${__fsg_ordered:+$__fsg_ordered }$__fsg_id"
      done <<FSG_EOF
$(parse_waves_table "$MISSION_DIR/waves.json")
FSG_EOF
    fi
    __fsg_sig="${LCARS_FS_SIGNAL_OUT:-$MISSION_DIR/fs-test-signal.txt}"; rm -f "$__fsg_sig"
    __fsg_rc=0
    FULL_SUITE_SIGNAL="$__fsg_sig" full_suite_gate $__fsg_ordered || __fsg_rc=$?
    printf 'FSRC=%s\n' "$__fsg_rc"
    exit 0 ;;
  # S92 test hook: exercise attachments_extra_block in ISOLATION. MISSION_DIR is
  # taken straight from $LCARS_ATT_TEST_DIR (no locate_mission, no worker spawn),
  # so a focused test can assert the block emits the ABSOLUTE attachment paths
  # when the dir has files and is empty when the dir is absent/empty.
  attachments-block-test)
    MISSION_DIR="${LCARS_ATT_TEST_DIR:-}"
    attachments_extra_block
    exit 0 ;;
  # S100 test hook: pure slice_pressure scalar — inputs via env (nCriteria /
  # nFiles / nDirs / newLoc / budget), echoes "<level>\t<reason>". Reads no CLI
  # name and spawns no worker, so the under-slice heuristic is unit-testable
  # offline + free. Inert for every real subcommand — reachable only by this token.
  slice-pressure-test)
    slice_pressure "${LCARS_SP_NC:-0}" "${LCARS_SP_NF:-0}" "${LCARS_SP_ND:-0}" \
      "${LCARS_SP_NEWLOC:-0}" "${LCARS_SP_BUDGET:-1200}"
    printf '\n'; exit 0 ;;
  # S100 test hook: build_slice_pressure_hint over a given plan.json (--plan),
  # optional per-ticket manifests (--manifests), and budget (the positional).
  # Emits the ADVISORY hint block the reviewer sees. NEVER rejects — always exit 0,
  # proving the signal cannot change a verdict. Inert for every real subcommand.
  slice-pressure-hint-test)
    build_slice_pressure_hint "$PLAN" "${MANIFESTS:-}" "${POSARG:-1200}"
    printf '\n'; exit 0 ;;
  # S101 test hook: pure test-convention detector — repo root via $LCARS_DTC_ROOT
  # (default $REPO_ROOT), target source via $LCARS_DTC_TARGET. Echoes exactly one of
  # co-located|__tests__|tests. Pure filesystem read; inert for every real subcommand.
  detect-test-convention-test)
    detect_test_convention "${LCARS_DTC_ROOT:-$REPO_ROOT}" "${LCARS_DTC_TARGET:-}"
    printf '\n'; exit 0 ;;
  # S101 test hook: pure path-mapper — convention via $LCARS_TPF_CONV, target source
  # via $LCARS_TPF_TARGET. Echoes the in-tree test relpath. Inert for real subcommands.
  test-path-for-test)
    test_path_for "${LCARS_TPF_CONV:-co-located}" "${LCARS_TPF_TARGET:-}"
    printf '\n'; exit 0 ;;
  # S101 test hook: run tests_unchanged for a ticket against the IN-TREE files under
  # $REPO_ROOT and print its rc (0 = unchanged, 1 = tampered/missing). Lets the fast
  # test prove a post-snapshot edit to the ridden-along in-tree test is still caught.
  tests-unchanged-test)
    locate_mission "$MISSION_ID"
    __tu_rc=0; tests_unchanged "$TICKET" || __tu_rc=$?
    printf 'TURC=%s\n' "$__tu_rc"; exit 0 ;;
  ''|*) die "unknown subcommand '${SUB:-}'. Usage: run.sh drive --mission <id> [--step], or a single Stage. Drivers: research|validate|plan|plan-review|implement|implement-ticket|drive. Persistence: gate|save|validate-pause|validate-advance|plan-save|review-save|schedule|impl-save-tests|impl-save-result|impl-status|impl-advance|verify-summary." ;;
esac
