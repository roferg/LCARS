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
# ABSOLUTE from here on. `$0` is whatever the caller typed, which may be relative
# to the caller's cwd — and a Stage that moves its cwd (S166: the front half now
# runs inside the Mission's own worktree) would then re-invoke a path that no
# longer resolves. Absolutising once, here, is cheaper than remembering it at
# every `bash "$SELF" …` site.
SELF="$SKILL_DIR/$(basename "$SELF")"
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
  # --git-common-dir, NOT --git-dir, for the same reason locate_mission uses it:
  # from inside a `git worktree` the plain --git-dir is that worktree's private
  # `.git/worktrees/<name>` dir, so the generated pack would resolve to a path
  # that has never existed — and a MISSING pack is not a no-op here, it SPAWNS a
  # cold worker to regenerate one. Every caller wants the SHARED pack.
  gitdir="$("$GIT_BIN" rev-parse --git-common-dir 2>/dev/null)" \
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
#
# S127 — THE HEADING NAMES WHAT ACTUALLY ARRIVED. The holodeck hands a Mission a
# `mockup.html` and a `concept.md` down this SAME road, and heading an HTML
# mockup as an *image* is a lie in the one prompt the cold worker reads most
# carefully. So the heading adapts:
#
#   • every attachment is an image  → the pre-S127 string, BYTE FOR BYTE. This
#     is shared pipeline code and the overwhelming majority of missions are
#     pasted screenshots; their prompt must not move by one character (asserted
#     against the literal string in tests/lcars-run-attachments.test.sh).
#   • anything else is present      → the block says what arrived, and when one
#     of them is a MOCKUP it carries the look-and-flow-only declaration WITH IT.
#
# The declaration rides here rather than only in the PRD on purpose: S164
# measured a live worker correctly refusing a decoy because SEVERAL places it
# could not miss all said the same thing, and S166 measured a live worker
# ignoring the same claim made in ONE place. This is one of those places — the
# prompt the worker is actually handed — and it is worded so a worker that reads
# nothing else still knows the mockup is not code.
#
# S128 (FL-010) — THE WORDING IS NOT SPELLED HERE. It was, and three other
# copies of the same sentence in `lcars file` and `lcars log` were missed while
# the byte-exact suite guarding THIS function stayed green. The classification,
# the tally, the heading noun and the mockup declaration all now come from the
# one shared rule in lcars-common.sh (lcars_attach_*), which `lcars file` (both
# lanes) and `lcars log` derive their prd.md section from too. What stays local
# is only what is genuinely local to a PROMPT: the parenthetical, and the fact
# that these are ABSOLUTE paths. Output is byte-identical to S127's on every
# input.
attachments_extra_block() {
  local d="$MISSION_DIR/attachments" f out="" list=""
  local paths=()
  [ -d "$d" ] || return 0
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    paths+=("$f")
    list="$list
- $f"
  done
  [ "${#paths[@]}" -gt 0 ] || return 0
  # Load the shared rule LAZILY, and only once there is something to head.
  # run.sh is re-entered as a subprocess for every Stage and every ticket, and
  # the overwhelming majority of missions have no attachments at all — sourcing
  # a second library into all of them to serve none of them is blast radius for
  # nothing. (Same reasoning as drive_load_base_lib, below.)
  if ! command -v lcars_attach_prd_section >/dev/null 2>&1; then
    local lib="${LCARS_COMMON_LIB:-$SKILL_DIR/../lcars-init/lcars-common.sh}"
    # shellcheck source=../lcars-init/lcars-common.sh
    [ -f "$lib" ] && . "$lib"
  fi
  # The parenthetical is the same on both branches, so it is written ONCE here;
  # only the noun (images / files) comes from the shared rule.
  out="
$(lcars_attach_heading "${paths[@]}") (the captain attached these; view/read them as part of your input)"
  # THE UNCHANGED PATH. Everything that is an image, and nothing that is not.
  if lcars_attach_all_images "${paths[@]}"; then
    printf '%s%s' "$out" "$list"
    return 0
  fi
  out="$out
What arrived: $(lcars_attach_tally "${paths[@]}"). Each is listed below by absolute path — open them."
  if lcars_attach_has_mockup "${paths[@]}"; then
    out="$out
$(lcars_attach_mockup_note)"
  fi
  printf '%s%s' "$out" "$list"
  return 0
}

# === The tickets carry the mockup (S169 fix round 2) =======================
#
# WHAT WAS MEASURED. A live drive filed a holodeck Mission carrying a mockup and
# planned it into 8 tickets / 44 acceptance criteria. NONE of the 44 referenced
# the mockup. "mock" appeared 15 times in ticket DESCRIPTIONS and 0 times in a
# criterion, and the planner stated the policy 8 times, once per ticket:
#
#     "Visual fidelity to the mockup is judged at Verify."
#     "Visual match is judged at Verify."  ×7
#
# A firm, uniform, deliberate policy — not an oversight. A builder could satisfy
# all 44 criteria without ever opening the drawing, and did: the delivered app
# kept the stated requirements and lost almost all of the look, with every gate
# green. Enriching the brief upstream cannot move that number, because the
# decision is made HERE, at Plan.
#
# WHY THIS IS NOT A CLASSIFIER. The obvious fix — read a ticket's prose and
# decide whether it is "visual" — is the road this project has lost four
# sessions to (S156's signal classifier fell 14/14 → 5/14 on a reworded corpus;
# S147 lost four generations of a source parser; S157 lost five versions of a
# guard). Nothing below reads a ticket to decide what it IS. The PLANNER
# declares `changesScreenAppearance` — it is the one party that knows, because
# it is writing the ticket — and the harness only checks that the declaration is
# present, is a boolean, and, when true, is BACKED by a criterion that contains
# the mockup's own filename. String containment on a name LCARS itself assigned.
# There is nothing to reword around.

# mission_mockup_names -> the basenames of this Mission's HTML mockups, space
# separated; EMPTY when it carries none. Classification comes from the ONE
# shared rule (lcars_attach_kind), never a second copy.
mission_mockup_names() {
  local d="$MISSION_DIR/attachments" f names=""
  [ -d "$d" ] || return 0
  # Lazy-load the shared rule, exactly as attachments_extra_block does and for
  # the same reason: run.sh is re-entered per Stage and per ticket, and almost
  # no mission has attachments at all.
  if ! command -v lcars_attach_kind >/dev/null 2>&1; then
    local lib="${LCARS_COMMON_LIB:-$SKILL_DIR/../lcars-init/lcars-common.sh}"
    # shellcheck source=../lcars-init/lcars-common.sh
    [ -f "$lib" ] && . "$lib"
  fi
  command -v lcars_attach_kind >/dev/null 2>&1 || return 0
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    [ "$(lcars_attach_kind "$f")" = mockup ] || continue
    names="${names:+$names }$(basename "$f")"
  done
  printf '%s' "$names"
}

# plan_mockup_contract_block -> the Plan prompt's mockup contract, or NOTHING
# when this Mission carries no mockup. A mission without one — which is every
# non-holodeck mission in the world — gets a byte-identical Plan prompt.
#
# It is worded to confront the planner's OWN settled view rather than merely
# adding a rule beside it. The "judged at Verify" sentence is not invented: the
# shared plan.md template teaches it ("mention the deferred judgment in the
# ticket's description, e.g. 'visual unobtrusiveness is judged at Verify'"), and
# that rule is CORRECT for a preference word with no stated delta. A mockup is
# the opposite of a preference word, so the carve-out is named explicitly — eight
# identical deferral sentences are what happens when a model's belief is left
# standing and a rule is stacked on top of it.
plan_mockup_contract_block() {
  local names; names="$(mission_mockup_names)"
  [ -n "$names" ] || return 0
  # The FIRST mockup names the contract in prose; every mockup is listed.
  local first="${names%% *}"
  printf '

## This Mission carries a MOCKUP — the tickets must carry it too

The captain attached a drawing of the screens this work must produce: %s
(absolute path listed above — open it). It is on disk and every Implementer who
builds one of your tickets can open it too.

### Declare it — `changesScreenAppearance`

Every ticket in this plan carries an ADDITIONAL boolean
**`changesScreenAppearance`**. Set it `true` when building the ticket changes
what a screen LOOKS LIKE — markup, layout, spacing, colour, type, on-screen
wording, an added or restyled control, a transition between screens. Set it
`false` when it does not: data, server, build, tooling or test-only work.
You are the one party that knows, because you are writing the ticket. Declare it
on EVERY ticket. The harness rejects a plan that omits it or gives it anything
other than a bare `true`/`false`.

### Carry it — every `true` ticket needs a criterion that NAMES the mockup

A ticket with `changesScreenAppearance: true` MUST have at least one entry in
its `acceptanceCriteria` containing the literal string `%s`. The harness
checks this deterministically and REJECTS the whole plan otherwise. Naming it in
the `description` does not count — the description is not what the work is
judged against.

Write a SPECIFIC criterion, not a general one. "Matches the mockup" is worth
nothing: an Implementer can claim it without opening the file, and the generic
losing to the specific is exactly how the look gets lost. Name WHAT about the
mockup THIS ticket'"'"'s surface must match, so the claim can be checked against the
drawing:

    BAD   "The sidebar matches the mockup"
    GOOD  "The sidebar nav reproduces %s'"'"'s nav list: the three items in
           that file'"'"'s order, each with its icon to the left of its label, the
           active item carrying the filled accent pill across the item'"'"'s full
           width, and the count badge right-aligned inside it"

So: open the mockup and read the surface each ticket owns BEFORE you write that
ticket'"'"'s criteria. The specifics come from the drawing, not from the brief.

### The look is NOT deferred to Verify — read this, it is the point

The rule above about splitting out human judgment — "mention the deferred
judgment in the description; the captain judges it at Verify" — is about
PREFERENCE WORDS with no stated delta: "unobtrusive", "looks right", "doesn'"'"'t
obscure gameplay". Those have no checkable content, so they are rightly left to
a human eye. A mockup is the OPPOSITE of a preference word. It is a concrete
artifact, on disk, that states the delta exactly. It is not taste, it is not
vague, and it is not deferred.

Verify is the captain'"'"'s DEMO DAY — his last look before he ships — not the
first place a wrong build is caught. A ticket that leaves the look to Verify is
built, tested and passed green by an Implementer who never opened the drawing;
what arrives at Verify then has the stated behaviour and none of the design, and
the captain'"'"'s only remaining move is to send the entire mission back. That is
not hypothetical — it is exactly what happened the last time a Mission carried a
mockup through this stage.

Do NOT write "visual fidelity to the mockup is judged at Verify", "visual match
is judged at Verify", or any sentence like them anywhere in this plan. The look
is part of the work, and the work is judged where it is built.

### The canonical shape, with the added field

    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "changesScreenAppearance": true,
    "rationale": "…"

The mockups this Mission carries:
%s' "$names" "$first" "$first" "$(printf '%s' "$names" | tr ' ' '\n' | sed 's/^/- /')"
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

# === The front half reads the Mission's own code (S166) =====================
#
# WHY THIS EXISTS. `mission_branch_block` above is PROSE, and prose is a request.
# S159's live Copilot drive measured what a real worker does with it: the worker
# read the sentence, SAID "The working tree may be unrelated. Let me check the
# mission branch content via git." — and then ran `view` on the working-tree path
# anyway. It never issued a single git command for the whole Stage. That drive
# came out right only because the base fast-forward had rewritten the checked-out
# tree on disk, and the checkout happened to be sitting on the base.
#
# So the guarantee LCARS actually shipped was "you are safe as long as the repo is
# on the Mission's base or its own branch when the Stage runs" — an unwritten rule
# the captain can violate by doing nothing more sinister than `git switch`. It has
# fired twice: the DX-Scorecard staleness failure that opened this round, and the
# S93 leak where a bug filed while the tree sat on a SIBLING Mission's branch had
# its Validator read THAT branch and conclude the feature was already fixed.
#
# The cure is not a better sentence. It is to make the Mission's code the only
# code in front of the worker: cut a disposable worktree at the Mission's branch
# and spawn the Stage there. Where the captain's checkout sits then stops
# mattering, because the worker cannot see it.
#
# DETACHED, NOT ATTACHED — the deliberate call. `git worktree add <path> <branch>`
# holds the ref, and git refuses one branch in two worktrees. Implement's reconcile
# gate cuts an ATTACHED worktree on the mission branch (see cmd_reconcile), and
# `replay_ticket_commit` checks that branch out in $REPO_ROOT itself; either would
# be BLOCKED by a front-half worktree still holding it, and a leaked one would
# block them forever. A detached checkout at the branch's sha has the identical
# TREE and holds no ref at all, so it can never contend. It is also the right shape
# on the merits: these four Stages are read-only (repo-read toolsets) and never
# commit, so a writable ref buys them nothing. `lcars launch` reached the same
# conclusion for the same reason — this reuses its pattern, it does not invent one.
#
# PROVISIONING: NONE, DELIBERATELY. `provision_worktree` exists for the gates,
# which must RUN the repo's test command and therefore need node_modules et al.
# Nothing in the front half executes the repo: the workers read. Installing deps
# here would buy nothing and cost twice — a full install per Stage, and a tree
# full of gitignored artifacts, which is precisely the seam that produced S157's
# false gate failure (LCARS's own node_modules symlink got counted as worker
# changes). If a future front-half Stage ever needs to RUN the repo, it should
# call the existing `provision_worktree` rather than grow a second install path.

# Where this Mission's disposable front-half checkout lives: a sibling of
# `launch/` under the SHARED .git/lcars, one per Mission (the four Stages are
# strictly sequential within a Mission, so one is enough) and deliberately NOT
# under $MISSION_DIR. Two reasons: nothing here is a Mission artifact and nothing
# should ever read it as one; and the board's SSE fingerprint is the max mtime of
# the files IN each mission dir, so a whole repo checked out there would bump the
# fingerprint on every cut and tear-down — churn for no new information.
front_half_wt_path() { printf '%s/stage-tree/%s' "$(dirname "$LCARS_CFG")" "$MISSION_ID"; }

# Set by enter_mission_worktree, read by leave_mission_worktree. Empty means this
# process owns no worktree and cleanup is a no-op.
FRONT_HALF_WT=""
# The cwd we were invoked in, so cleanup can step OUT of a tree before removing it.
FRONT_HALF_HOME="$PWD"

# Remove + prune this process's worktree. Armed on EXIT/INT/TERM the moment one is
# cut, so it runs on EVERY path out — the clean `exit 0`, a `die`, a watchdog kill.
# A leaked worktree is not cosmetic: it survives as a registration that later
# `worktree add`s trip over, which is how gates have been blocked before.
leave_mission_worktree() {
  [ -n "$FRONT_HALF_WT" ] || return 0
  local wt="$FRONT_HALF_WT"; FRONT_HALF_WT=""
  # Step out first — git will not remove the tree you are standing in, and the
  # rm -rf fallback would leave the shell in a deleted directory.
  cd "$FRONT_HALF_HOME" 2>/dev/null || cd / 2>/dev/null || :
  "$GIT_BIN" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  "$GIT_BIN" worktree prune >/dev/null 2>&1 || :
  # Tidy the container when it empties; a concurrent Mission's tree keeps it.
  rmdir "$(dirname "$wt")" >/dev/null 2>&1 || :
  return 0
}

# Cut the worktree at <ref> and MOVE THIS PROCESS INTO IT, so every worker this
# Stage spawns inherits it as cwd. <ref> is the branch the caller has already
# resolved as "the Mission's code" — the same branch its prose block names, so
# structure and prose can never disagree.
#
# NO RECORDED BRANCH ⇒ NO WORKTREE. A Mission whose branch ref does not exist
# (an unborn HEAD, a branch-less local mission) has no code of its own that is
# distinct from the ambient checkout, so there is nothing to isolate and we say
# so out loud rather than pretending.
#
# A FAILED CUT IS FATAL, NOT A FALLBACK. Carrying on in the ambient tree is
# exactly the defect this closes, and it would be invisible — the Stage would go
# green having reasoned about someone else's code. S111 settled this doctrine for
# Implement's worktree ("REFUSING the in-tree fallback"); the front half gets the
# same answer, with the same actionable message.
enter_mission_worktree() { # <ref> <stage-label>
  local ref="$1" stage="${2:-}"
  if [ -z "$ref" ] || ! "$GIT_BIN" show-ref --verify --quiet "refs/heads/$ref"; then
    printf '  ⌂ no branch of its own — this Stage reads the checkout it was run from.\n'
    return 0
  fi
  local wt; wt="$(front_half_wt_path)"
  if ! mkdir -p "$(dirname "$wt")" 2>/dev/null; then
    die "cannot create $(dirname "$wt") to hold this Stage's checkout of '$ref' (path blocked by a file?) — Stage stopped. LCARS will not read a Stage's code out of whatever tree happens to be checked out."
  fi
  # Start from a clean slate: a previous Stage that was killed hard (watchdog,
  # SIGKILL) can leave both the dir and its registration behind.
  "$GIT_BIN" worktree remove --force "$wt" >/dev/null 2>&1 || :
  rm -rf "$wt"
  local add_err=""
  if ! add_err="$("$GIT_BIN" worktree add -q --detach "$wt" "$ref" 2>&1 >/dev/null)"; then
    # The dominant cause is a STALE registration — a worktree dir deleted without
    # a prune. Prune and retry once; only a second failure is terminal.
    "$GIT_BIN" worktree prune >/dev/null 2>&1 || :
    rm -rf "$wt"
    if ! add_err="$("$GIT_BIN" worktree add -q --detach "$wt" "$ref" 2>&1 >/dev/null)"; then
      rm -rf "$wt"
      die "could not check out '$ref' into $wt (git: $(printf '%s' "$add_err" | tr '\n' ' ')) — Stage stopped, no advance. This Stage must read THIS Mission's code, and falling back to the ambient checkout would let it reason about whatever branch you happen to be on. Free or prune stale worktrees (\`git worktree list\`, \`git worktree prune\`) and re-run."
    fi
  fi
  FRONT_HALF_WT="$wt"
  trap 'leave_mission_worktree' EXIT INT TERM
  cd "$wt" || die "could not enter $wt — Stage stopped."
  # $REPO_ROOT is what the rest of this process means by "the repository".
  REPO_ROOT="$wt"
  # OUT-OF-WORKTREE INPUT READ GRANTS — the same seam Implement uses (S76). Every
  # artifact this Stage feeds its worker (prd.md, research/*.json, plan.json, the
  # context pack, attachments) lives under the shared .git/lcars, which is OUTSIDE
  # the worktree; a CLI with a hard path sandbox (copilot) could otherwise read
  # none of them. READ-only, and a tidy superset — it widens nothing else.
  export LCARS_WORKER_INPUT_DIRS="$(dirname "$LCARS_CFG")"
  printf '  ⌂ mission tree — %s reads '"'"'%s'"'"' @ %s in an isolated worktree (your checkout is untouched)\n' \
    "${stage:-this Stage}" "$ref" "$("$GIT_BIN" -C "$wt" rev-parse --short HEAD 2>/dev/null)"
  return 0
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
- $MISSION_DIR/manifests/$tid.md   (this ticket's context manifest — relevant files + interface signatures + touched ADR ids; NAVIGATION ONLY, not the implementation. Use the listed files to find the PUBLIC INTERFACE to test against; author the ticket's tests in-tree at the repo's own convention.)"
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

# A PARKED mission (`"prdPending": true`, filed via `lcars file --park`) sits at
# stage "align" but has NO PRD yet — Research, and every downstream Stage, would
# have nothing to consume. Refuse cleanly, naming the align command, rather than
# letting a Stage die on a missing prd.md with a confusing message (or worse,
# have the driver spin it). The invariant this protects — "a Stage consumes
# artifacts that exist" — is old; only the actionable message is new.
refuse_if_parked() {
  local pend; pend="$(json_raw "$STATE" prdPending)"
  [ "$pend" = "true" ] || return 0
  die "Mission $MISSION_ID is parked awaiting alignment — run \`lcars file $MISSION_ID\` to align it first."
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
# The remove-list carries lcars:research as well as lcars:align because Research
# now applies its own IN-FLIGHT label while it runs (see cmd_research) — the card
# has to leave the Research column when it lands in Validate. Removing a label
# that is not present is a no-op for `gh issue edit`, exactly as with the
# lcars:awaiting-human entries the other advances carry, so the paths that reach
# here without an in-flight apply (a bare `save` / `gate` invocation) are
# unchanged.
advance() {
  set_stage "validate"
  gh_relabel "lcars:validate" "lcars:align lcars:research"
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
#
# The optional second argument is the space-separated list of the Mission's HTML
# MOCKUP basenames (see mission_mockup_names). EMPTY — which is every mission
# that did not come from the holodeck — makes every rule below it inert, so a
# no-mockup plan is validated EXACTLY as it was before S169. When it is
# non-empty, three further DECLARATION checks apply; none of them reads a
# ticket's prose to decide anything (see the design note above
# plan_mockup_contract_block).
validate_plan_json() { # file [mockup-basenames]
  awk -v mock="${2:-}" '
    function fail(msg) { printf "lcars run: %s\n", msg > "/dev/stderr"; exit 1 }
    # Does the accumulated acceptance-criteria TEXT of this ticket name one of
    # the Mission mockups? Plain string containment on a filename LCARS itself
    # assigned — no regex, no semantics, nothing to reword around.
    function names_mockup(t,   i) {
      for (i = 1; i <= nmock; i++) if (index(t, mockname[i]) > 0) return 1
      return 0
    }
    BEGIN { nmock = (mock == "" ? 0 : split(mock, mockname, " ")) }
    # object boundaries — canonical format puts { and } on their own lines, and
    # the only braces in the file are object delimiters (arrays are inline).
    /^[[:space:]]*\{[[:space:]]*$/ {
      inobj=1; delete have; acok=0; id=""; ndep=0; in_ac=0; actext=""; visual=""; next
    }
    /^[[:space:]]*\}[,]?[[:space:]]*$/ {
      if (!inobj) next
      tickets++
      for (k=1; k<=9; k++) if (!have[req[k]]) fail("ticket " tickets " is missing \"" req[k] "\".")
      if (!acok) fail("ticket " tickets " (" id ") needs at least one acceptance criterion.")
      # --- S169: the tickets must carry the mockup ---------------------------
      # Only for a Mission that ACTUALLY carries one. The planner DECLARES;
      # we check the declaration is there, is a boolean, and — when it says this
      # ticket changes a screen — that a criterion names the drawing.
      if (nmock > 0) {
        if (!have["changesScreenAppearance"])
          fail("ticket " tickets " (" id ") is missing \"changesScreenAppearance\" — this Mission carries a mockup (" mock "), so every ticket must declare whether it changes what a screen looks like.")
        if (visual != "true" && visual != "false")
          fail("ticket " tickets " (" id ") has a non-boolean \"changesScreenAppearance\": " visual " — use true or false.")
        if (visual == "true") {
          nvisual++
          if (!names_mockup(actext))
            fail("ticket " tickets " (" id ") declares changesScreenAppearance:true but NO acceptance criterion references the mockup (" mock "). Add a criterion naming that file and saying what about it this ticket'"'"'s surface must match — the look is built here, not judged at Verify. Naming it in the description does not count.")
        }
      }
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
      actext = actext " " $0   # S169 — see the note on the inline branch below
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
        # S169: accumulate this ticket'"'"'s CRITERIA TEXT for the mockup check. The
        # check reads THIS and nothing else — never the description: the measured
        # plan named the mockup once, in a DESCRIPTION, while all 44 criteria
        # ignored it, and the description is not what the work is judged against.
        #
        # Take the whole line MINUS the key rather than the even split() indices.
        # A criterion legitimately contains escaped quotes (the measured plan has
        # `data-theme=\"dark\"` in three of them), which SHIFT the odd/even parity
        # and would drop half the text on the floor — a FALSE REJECT of an honest
        # plan. Everything after the key on this line is criteria text, so there
        # is nothing to be gained by being cleverer.
        v=$0; sub(/.*"acceptanceCriteria"[[:space:]]*:[[:space:]]*/, "", v)
        actext = actext " " v
        if ($0 !~ /\]/) in_ac=1     # array opens here, closes on a later line
      }
      else if (key=="dependencies") { for (i=4; i<=n; i+=2) if (a[i] != "") dep[++ndep]=a[i] }
      # S156: `establishesSharedInfrastructure` is OPTIONAL — absent must stay
      # valid (in-flight missions and every pre-S156 plan). When PRESENT it must
      # be a boolean: the Schedule stage groups on it, so a mistyped value would
      # silently mis-schedule the whole plan.
      else if (key=="establishesSharedInfrastructure") {
        v=$0; sub(/.*"establishesSharedInfrastructure"[[:space:]]*:[[:space:]]*/, "", v)
        gsub(/[ ,]/, "", v)
        if (v!="true" && v!="false" && v!="\"true\"" && v!="\"false\"")
          fail("ticket " (tickets+1) " (" id ") has a non-boolean \"establishesSharedInfrastructure\": " v " — use true or false.")
      }
      # S169 — the planner'"'"'s DECLARATION that this ticket changes what a screen
      # looks like. Captured the same way as the flag above (a BARE boolean has
      # no quoted value, so read the raw token after the colon); judged at the
      # object close, and ONLY when the Mission actually carries a mockup.
      else if (key=="changesScreenAppearance") {
        v=$0; sub(/.*"changesScreenAppearance"[[:space:]]*:[[:space:]]*/, "", v)
        gsub(/[ ,"]/, "", v)
        visual=v
      }
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
      # S169 — close the one-word escape. Without this, a plan satisfies the
      # per-ticket rule above by declaring every ticket false, and the gate is
      # theatre. This is a check on the DECLARATIONS, not on any ticket'"'"'s prose:
      # the captain drew screens and attached them, so a plan in which nothing
      # changes a screen contradicts the Mission'"'"'s own premise.
      if (nmock > 0 && nvisual == 0)
        fail("no ticket in this plan declares changesScreenAppearance:true, but the Mission carries a mockup (" mock ") — a drawing of the screens the work must produce. Declare the tickets that change what a screen looks like and give each one a criterion naming that file.")
    }
  ' "$1"
}

# --- subcommand: plan-save -------------------------------------------------
cmd_plan_save() {
  locate_mission "$MISSION_ID"
  require_stage plan

  [ -n "$PLAN" ] && [ -f "$PLAN" ] || die "no plan file — pass --plan <file>."

  # S169: the second argument is this Mission's HTML mockup basenames, or EMPTY.
  # Empty leaves the validator behaving exactly as it did before — which is the
  # case for every mission that did not come from the holodeck.
  validate_plan_json "$PLAN" "$(mission_mockup_names)" || exit 1

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
  # S156: say it at the EARLIEST point a human or Plan Review can act on it. A
  # plan that declares `establishesSharedInfrastructure` on NO ticket leaves
  # Schedule reading ticket text instead, which only catches a ticket that names
  # a config file — so an unnamed scaffold ticket would share wave 1 with the
  # tickets that build on it. Not a gate: the plan is saved either way.
  local ndecl ntk
  ndecl="$(parse_plan_table "$MISSION_DIR/plan.json" 2>/dev/null | awk -F'\t' '$7!=""{n++} END{print n+0}')"
  ntk="$(parse_plan_table "$MISSION_DIR/plan.json" 2>/dev/null | grep -c .)"
  if [ "${ndecl:-0}" -eq 0 ] && [ "${ntk:-0}" -gt 0 ]; then
    echo "  ⚠ no ticket declares establishesSharedInfrastructure — Plan Review should ask for it. Without it, Schedule falls back to reading ticket text and only isolates a ticket that NAMES a build/test config file."
  fi
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
#
# S156: one ADDITIONAL, deterministic grouping rule sits on top of the graph — a
# ticket that ESTABLISHES SHARED BUILD/TEST INFRASTRUCTURE rides ALONE in its
# wave and acts as a barrier in plan order, so nothing that will build against
# that infrastructure can be its blind sibling. The call is the ticket's own
# DECLARED `establishesSharedInfrastructure`, with a heuristic backstop only when
# the field is absent (see classify_infra_ticket). Such a wave carries an
# additive "reason" in waves.json (and a line in the readout) that says which of
# the two decided it. Ticket isolation itself is unchanged.

# --- parse approved-plan.json into a tab-separated ticket table -------------
# One line per ticket:
#   id \t title \t description \t criteria \t deps \t rationale \t infraFlag
# criteria items are joined with " | " and deps with spaces — both are inline
# single-line arrays in the canonical shape, so no field ever spans lines. Same
# jq-free, line-oriented parse as validate_plan_json.
#
# Fields 6–7 are S156 additions, APPENDED so every existing consumer is
# unaffected (they read $1..$5, or `read id title desc crit deps` where the last
# variable absorbs the tail):
#   rationale  — the planner's *why*; the sentence most likely to say "this
#                establishes the shared test infrastructure", and previously
#                dropped on the floor.
#   infraFlag  — the ticket's DECLARED `establishesSharedInfrastructure`
#                ("true"/"false"), or EMPTY when the ticket does not declare it.
#                Empty is the signal to fall back to the heuristic backstop.
parse_plan_table() { # file
  awk '
    function flush() {
      if (id=="") return
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, title, desc, crit, deps, rat, infra
    }
    /^[[:space:]]*\{[[:space:]]*$/ { inobj=1; id=""; title=""; desc=""; crit=""; deps=""; rat=""; infra=""; next }
    /^[[:space:]]*\}[,]?[[:space:]]*$/ { if (inobj) flush(); inobj=0; next }
    inobj {
      n=split($0, a, "\"")             # inside-quote contents land at even indices
      if (n < 2) next
      key=a[2]
      if (key=="id") id=a[4]
      else if (key=="title") title=a[4]
      else if (key=="description") desc=a[4]
      else if (key=="rationale") rat=a[4]
      else if (key=="acceptanceCriteria") { c=""; for (i=4;i<n;i+=2) if (a[i]!="") c=(c==""?a[i]:c" | "a[i]); crit=c }
      else if (key=="dependencies")       { d=""; for (i=4;i<n;i+=2) if (a[i]!="") d=(d==""?a[i]:d" "a[i]); deps=d }
      # A BARE boolean has no quoted value, so read the raw token after the
      # colon (and tolerate a quoted "true"/"false" from a sloppy worker).
      else if (key=="establishesSharedInfrastructure") {
        v=$0; sub(/.*"establishesSharedInfrastructure"[[:space:]]*:[[:space:]]*/, "", v)
        gsub(/[ ,"]/, "", v)
        if (v=="true" || v=="false") infra=v
      }
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

# === is this ticket INFRASTRUCTURE-ESTABLISHING? (S156) =====================
# Why any of this exists (ground truth, mission lcars-20260727-001, 2026-07-27):
# wave 1 held BOTH t-001 (Vite + React + TS scaffold) and t-012 (docs + a vitest
# suite), because t-012 declared no CODE dependency on t-001 — but it depended
# totally on the TEST INFRASTRUCTURE t-001 was creating. Siblings in a wave are
# blind to each other by design, so t-012 authored its test against a base with
# no Vite config; t-001's vite.config.ts then made that file throw at import
# time and its 13 tests silently stopped running for eleven more tickets.
#
# ONE MECHANISM, plus a deliberately narrow safety net:
#
#   1. DECLARED — THE MECHANISM. The Plan worker sets
#      `establishesSharedInfrastructure` on the ticket (see stages/plan.md), and
#      Plan Review audits it (see stages/plan-review.md) the same way it audits
#      dependencies. When the field is present the harness OBEYS it — true
#      isolates, false never does, and no prose is inspected at all. This is not
#      a new LLM call, a new stage, or a new worker: it is one more declared
#      field on an artifact the planner already writes, read exactly the way
#      `dependencies` is.
#
#   2. BACKSTOP — a narrow, HIGH-PRECISION net for plans whose worker omitted
#      the field (an older plan, a mission already in flight). It is NOT a
#      classifier and does not try to be one.
#
# WHY THE BACKSTOP IS THIS SMALL — measured, not assumed. An earlier version of
# it also matched infrastructure PHRASES ("the test runner", "the package
# layout", "install pytest", scaffold/bootstrap wording). An adversarial tester
# took its own 14-item corpus, reworded each item preserving meaning, and recall
# fell from 14/14 to 5/14 ("Add the CI workflow that runs the tests on every
# push" caught, "Add the GitHub Actions job that runs the unit tests on push"
# missed); on 50 unseen tickets it scored 13/23 infra caught, 18/25 ordinary
# clean. Prose matching does not generalise — it recognises the sentences it was
# fitted to — and it was wrong in BOTH directions, so those signals were deleted
# rather than widened again.
#
# WHAT THE BACKSTOP DOES NOT CATCH — state this plainly, it is the trade:
# ANY infrastructure ticket that never names a config file. "Create the Django
# project and its settings module", "Stand up the test runner", "Install RSpec
# and a first spec", "Migrate the existing Jest suites onto Vitest", "Add the
# GitHub Actions job that runs the unit tests" — all MISSED, by design.
# tests/wave-isolation.test.sh encodes those as explicit KNOWN-MISS assertions
# so the file documents the real recall instead of flattering it. That is
# acceptable ONLY because the declared field is the mechanism and Plan Review
# audits it; the Schedule readout says out loud when a plan declared nothing, so
# a captain can see they are running on the net rather than the mechanism.
#
# THE ONE RESIDUAL FALSE-POSITIVE CLASS — a repo whose SUBJECT MATTER is build
# configuration. The backstop cannot tell "this ticket CHANGES vite.config" from
# "this ticket adds a FEATURE that reads vite.config", so a dependency scanner, a
# language server, a CI dashboard or a template gallery trips it: "Add Gemfile
# support to the audit tool", "Add tsconfig support to the language server",
# "Convert the uploaded pom.xml into the internal model", "Add the .csproj upload
# endpoint", "Add the diff viewer for lockfile changes", "Add the CI status
# column". LCARS itself is such a repo. Declaring
# `establishesSharedInfrastructure` makes the class vanish entirely, because the
# text is then never read; and the cost while undeclared is WALL-CLOCK ONLY —
# extra one-ticket waves, never wrong code, never a skipped ticket.
#
# Both paths are deterministic — no LLM call at Schedule time.

# --- the backstop's vocabulary ----------------------------------------------
# Everything here is exercised by the corpora in tests/wave-isolation.test.sh.
#
# BLOCK — a LINE framed as a negation ("no changes to go.mod are needed", "it
# does not introduce tsconfig changes"), as reuse of something that already
# exists ("uses the existing spec_helper"), or as a documentation/link reference
# ("add a Gemfile entry note in the contributing guide") contributes NO signal.
# Blocking is per LINE, so a ticket's other lines can still fire.
#
# ANCHORED, like every other pattern here. Unanchored, these fragments swallowed
# genuine infrastructure lines through unrelated substrings — measured:
# "guide" ⊂ styleguide/guidelines and "display" ⊂ displays killed
# "Add vite.config.ts as described in the styleguide.", "Create tsconfig per our
# guidelines." and "Create pytest.ini; the runner displays progress." All three
# classify again; each is a regression case in tests/wave-isolation.test.sh.
#
# It still costs recall on purpose — a genuine infrastructure line that says
# "existing" ("add vite.config.ts to the existing repo") is swallowed — which is
# the right direction for a net that must never serialise a plan on a false
# positive.
INFRA_BLOCK_PHRASE_RE='no (change|changes|new|modification)|not (change|changes|modify|touch|add|need|introduce|create|use|require)|none of|rather than|without (changing|changed|modifying|modify|adding|add)|already|existing|unchanged|re-?uses?|documented|document the|guides?|readme|changelog|note in|badge|link the|links? to|mentions?|mentioned|lists|is listed|equals|field of|refer to|references the|reads? the|read from|displays? the|shows? the'
INFRA_BLOCK_RE="(^|[^a-z0-9-])($INFRA_BLOCK_PHRASE_RE)([^a-z0-9-]|\$)"
# VERB — the imperative verbs plan.md mandates, plus their -s forms (a rationale
# is written in the third person: "this ticket also creates vitest.config.ts").
# CREATE verbs stand up something new; CHANGE verbs restructure something shared
# that already exists. `port` is
# deliberately ABSENT: it is a noun far more often than a verb in ticket text
# ("reads the port from package.json", "display the port the dev server bound,
# from vite.config") and both of those are ordinary product work.
INFRA_CREATE_VERB_RE='add(s)?|creat(e|es)|introduc(e|es)|install(s)?|set(s)? ?up|stand(s)? ?up|initiali[sz]e(s)?|scaffold(s)?|bootstrap(s)?|generat(e|es)|establish(es)?|wir(e|es) up|lay(s)? out|configur(e|es)'
INFRA_CHANGE_VERB_RE='migrat(e|es)|upgrad(e|es)|restructur(e|es)|replac(e|es)|switch(es)?|convert(s)?|rework(s)?|consolidat(e|es)|extract(s)?'
INFRA_VERB_RE="\\b($INFRA_CREATE_VERB_RE|$INFRA_CHANGE_VERB_RE)\\b"
# FILE — shared build/test config files across every stack LCARS supports
# (js/ts, python, rust, go, dotnet, ruby, jvm) plus CI. Two lists because the
# boundary rules differ: a NAME must not be a substring of a longer identifier
# ("django.models" must not match `go.mod`), while an EXTENSION legitimately
# follows one ("Web.csproj"). EVERY pattern that survives in this file is
# boundary-anchored — the unanchored object lists that let "repo" match "report"
# and "cli" match "client" were deleted with the rest of the phrase matching.
INFRA_FILE_NAME_RE='package\.json|package-lock\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|yarn\.lock|bun\.lockb|npm-shrinkwrap\.json|vite\.config|vitest\.config|vitest\.setup|jest\.config|jest\.setup|webpack\.config|rollup\.config|esbuild\.config|next\.config|babel\.config|karma\.conf|setuptests|test-setup|setup-tests|setupfiles|tests?/setup\.|tsconfig|pytest\.ini|conftest\.py|pyproject\.toml|setup\.cfg|tox\.ini|requirements\.txt|pipfile|poetry\.lock|cargo\.toml|cargo\.lock|go\.mod|go\.sum|directory\.build\.props|nuget\.config|gemfile|spec_helper|rails_helper|pom\.xml|build\.gradle|settings\.gradle|gradle\.properties|\.github/workflows'
INFRA_FILE_EXT_RE='\.csproj|\.sln|\.babelrc|\.rspec'
# Both boundaries for a NAME; only a trailing one for an EXTENSION.
INFRA_FILE_RE="((^|[^a-z0-9.-])($INFRA_FILE_NAME_RE)|($INFRA_FILE_EXT_RE))([^a-z0-9-]|\$)"

# infra_heuristic — THE WHOLE BACKSTOP, one signal: a shared build/test config
# FILE named on an unblocked line that also carries a create/change verb. Echoes
# the file it matched (evidence for the reason string) and returns 0. This is an
# inference from text, never a fact: callers must word it as one.
infra_heuristic() { # declared-text -> echoes the matched config file; rc 0 = looks infra
  local text lines m
  text="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  lines="$(printf '%s\n' "$text" | grep -Ev "$INFRA_BLOCK_RE")"
  [ -n "$lines" ] || return 1
  m="$(printf '%s\n' "$lines" | grep -E "$INFRA_VERB_RE" | grep -Eo "$INFRA_FILE_RE" | head -n 1)"
  [ -n "$m" ] || return 1
  # trim the boundary characters the anchored pattern captures
  printf '%s' "$m" | sed 's/^[^a-z0-9._/]*//; s/[^a-z0-9_]*$//'
}

# The text the backstop reads from a plan-table line: title, description, each
# acceptance criterion on its own line, and the RATIONALE (where a planner most
# naturally explains what a ticket stands up).
ticket_declared_text() { # plan-table-line
  printf '%s\n%s\n%s\n%s' \
    "$(printf '%s' "$1" | cut -f2)" \
    "$(printf '%s' "$1" | cut -f3)" \
    "$(printf '%s' "$1" | cut -f4 | tr '|' '\n')" \
    "$(printf '%s' "$1" | cut -f6)"
}

# classify_infra_ticket — the ONE entry point. Given a plan-table LINE, echo
#   "declared\t<flag-text>"   the ticket declared establishesSharedInfrastructure
#   "inferred\t<config-file>" the field was absent and the backstop fired
# and return 0 when the ticket is infrastructure-establishing; 1 otherwise
# (including an explicit `false`, which is obeyed WITHOUT consulting the prose).
classify_infra_ticket() { # plan-table-line
  local line="$1" flag m
  flag="$(printf '%s' "$line" | cut -f7)"
  case "$flag" in
    true)  printf 'declared\testablishesSharedInfrastructure: true'; return 0 ;;
    false) return 1 ;;
  esac
  m="$(infra_heuristic "$(ticket_declared_text "$line")")" || return 1
  printf 'inferred\t%s' "$m"
}

# infra_scan — ONE pass over the plan table producing the provenance of every
# ticket, so Schedule can both group AND tell the captain how each call was made:
#   id \t declared-true  \t (empty)
#   id \t declared-false \t <config file the backstop WOULD have matched, if any>
#   id \t inferred       \t <config file matched>
#   id \t none           \t (empty)
# `declared-false` with evidence is a CONTRADICTION: the plan overrules the text.
# The planner's call still wins — Schedule only says so out loud.
infra_scan() { # table-file
  local line id flag m
  while IFS= read -r line; do
    id="$(printf '%s' "$line" | cut -f1)"
    [ -n "$id" ] || continue
    flag="$(printf '%s' "$line" | cut -f7)"
    if [ "$flag" = "true" ]; then
      printf '%s\tdeclared-true\t\n' "$id"
      continue
    fi
    m="$(infra_heuristic "$(ticket_declared_text "$line")")" || m=""
    if [ "$flag" = "false" ]; then
      printf '%s\tdeclared-false\t%s\n' "$id" "$m"
    elif [ -n "$m" ]; then
      printf '%s\tinferred\t%s\n' "$id" "$m"
    else
      printf '%s\tnone\t\n' "$id"
    fi
  done <"$1"
}

# The classification of ONE ticket of the plan table, by id (rc 1 = not infra).
ticket_infra_signal() { # table-file  ticket-id
  local line; line="$(awk -F'\t' -v want="$2" '$1==want{print; exit}' "$1")"
  [ -n "$line" ] || return 1
  classify_infra_ticket "$line"
}

# Every infrastructure-establishing ticket id, space-separated, in plan order —
# read off the infra_scan output so the table is classified exactly once. This
# is what compute_waves isolates.
infra_ids_from_scan() { # scan-file
  awk -F'\t' '$2=="declared-true" || $2=="inferred" { printf "%s ", $1 }' "$1" | sed 's/ *$//'
}

# --- group tickets into waves; detect cycles --------------------------------
# Reads the ticket table (id in field 1, deps in field 5) and prints one line
# per wave: "<wave-number> <id> <id> …", tickets in plan order. On a cycle — a
# round that can place no ticket while some remain — prints a clear error naming
# the stuck tickets to stderr and exits non-zero, so the caller changes nothing.
#
# $2 (optional) is the space-separated list of INFRASTRUCTURE-ESTABLISHING
# ticket ids (see classify_infra_ticket). Each such ticket is a BARRIER in plan
# order:
#   • it rides ALONE in its wave — a wave that already holds tickets never
#     absorbs it, and it never absorbs a sibling;
#   • no ticket AFTER it in plan order may share that wave or land in an earlier
#     one, so every later ticket builds AGAINST the infrastructure, not beside it;
#   • tickets BEFORE it in plan order keep the early wave they already had.
# With an EMPTY list this is byte-for-byte the pre-S156 layered Kahn — the
# no-infra plan's waves.json is unchanged.
#
# DEPENDENCIES ALWAYS WIN, and the ONLY way they win is by NARROW relaxation. A
# plan whose infra ticket depends on a ticket ordered AFTER it cannot satisfy the
# barrier and the dependency at once; when the barrier empties a round, the round
# is retried admitting ONLY the still-unplaced tickets in the transitive
# dependency closure of THE ONE infra ticket that blocked it — the first unplaced
# infra ticket in plan order, which is where the strict pass breaks (`clo` exists
# for exactly this). An unrelated later ticket with no dependencies never gets in
# that way.
#
# It CAN still end up ahead of a LATER barrier, and that is graph-forced, not a
# leak: with two infra tickets, a ticket admitted as the FIRST one's dependency
# is already placed when the SECOND one is isolated, and it may sit later in plan
# order than the second. No wave layout satisfies both barriers and both
# dependency edges. The emitted reason discloses it — that ticket is named as
# having built earlier WITHOUT being called a dependency (see
# wave_isolation_reason, which checks every dependency claim against the graph).
#
# The cycle path stays reserved for a REAL dependency cycle — the narrowed round
# still places nothing only when nothing is ready at all.
compute_waves() { # table-file [infra-ids]
  awk -F'\t' -v infra_list="${2:-}" '
    BEGIN { ni=split(infra_list, ia, " "); for (i=1;i<=ni;i++) if (ia[i]!="") isinfra[ia[i]]=1 }
    { order[++count]=$1; depstr[$1]=$5 }
    END {
      for (k=1;k<=count;k++) {
        id=order[k]; idx[id]=k; nd=split(depstr[id], dd, " "); ndep[id]=0
        for (j=1;j<=nd;j++) if (dd[j]!="") { ndep[id]++; dep[id, ndep[id]]=dd[j] }
      }
      # Transitive dependency closure of each infra ticket (fixpoint; N is tiny).
      # Used by the NARROWED relaxation below, and nowhere else.
      for (k=1;k<=count;k++) {
        b=order[k]; if (!isinfra[b]) continue
        for (i=1;i<=ndep[b];i++) clo[b, dep[b,i]]=1
        changed=1
        while (changed) {
          changed=0
          for (j=1;j<=count;j++) {
            m=order[j]
            if (!((b SUBSEP m) in clo)) continue
            for (i=1;i<=ndep[m];i++)
              if (!((b SUBSEP dep[m,i]) in clo)) { clo[b, dep[m,i]]=1; changed=1 }
          }
        }
      }
      placed=0; wave=0
      while (placed < count) {
        wave++
        # relax=0: the barrier holds. relax=1: retried ONLY when the barrier
        # emptied the round, and then ONLY for the unplaced dependency closure of
        # the SINGLE infra ticket that blocked it (the first unplaced one).
        for (relax=0; relax<=1; relax++) {
          if (relax) {
            # ONE blocked infra ticket broke the strict round: the FIRST unplaced
            # infra ticket in plan order (that is where the strict pass breaks).
            # Admit ONLY its own unplaced dependency closure. A UNION over every
            # blocked infra ticket would let a ticket needed by a LATER infra
            # ticket sail past an EARLIER barrier — an unjustified breach.
            delete allow
            for (k=1;k<=count;k++) {
              b=order[k]
              if (done[b] || !isinfra[b]) continue
              bready=1
              for (i=1;i<=ndep[b];i++) if (!done[dep[b,i]]) { bready=0; break }
              if (!bready)
                for (j=1;j<=count;j++) {
                  m=order[j]
                  if (!done[m] && ((b SUBSEP m) in clo)) allow[m]=1
                }
              break
            }
          }
          wc=0
          for (k=1;k<=count;k++) {
            id=order[k]
            if (done[id]) continue
            if (relax && !(id in allow)) continue
            ready=1
            for (i=1;i<=ndep[id];i++) if (!done[dep[id,i]]) { ready=0; break }
            blocked = (!ready || floor[id] > wave)
            if (isinfra[id]) {
              if (blocked) { if (relax) continue; else break }
              if (wc > 0) break          # this wave has started — infra waits
              ready_id[++wc]=id
              break                      # …and once placed, rides alone
            }
            if (blocked) continue
            ready_id[++wc]=id
          }
          if (wc > 0) break
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
        # A lone infra ticket raises the floor for EVERY later-in-plan-order
        # ticket: they cannot share this wave and (being unplaced) cannot have
        # landed in an earlier one. No closure exemption is needed here — a
        # closure member ordered after the infra ticket is already `done` by the
        # time the infra ticket can be placed at all.
        if (wc==1 && isinfra[ready_id[1]]) {
          b=ready_id[1]
          for (j=idx[b]+1; j<=count; j++)
            if (floor[order[j]] < wave+1) floor[order[j]]=wave+1
        }
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
# Input lines: "<wave>\t<id>\t<issue>[\t<reason>]" in wave then plan order. Emits
# the canonical waves.json — an array of { wave, tickets:[ { id, issue } ] }.
#
# S156: a wave the infra-ticket barrier ISOLATED also carries a human-readable
# `"reason"` naming the ticket and why it rides alone. ADDITIVE and ABSENT when
# the wave was not isolated (the house convention, cf. meta.testReadiness), so a
# plan with no infrastructure ticket emits byte-identical waves.json. The reason
# sits between "wave" and "tickets" and contains no quotes, so every jq-free
# line-oriented reader (parse_waves_table, ticket_issue, render.sh's
# read_waves_totals, local_adapter.py) parses it unchanged.
emit_waves_json() { # assignments-file
  awk -F'\t' '
    { w=$1; if (!(w in seen)) { seen[w]=1; worder[++nw]=w }
      cnt[w]++; tid[w, cnt[w]]=$2; tiss[w, cnt[w]]=$3
      if (NF >= 4 && $4 != "" && !(w in reason)) reason[w]=$4 }
    END {
      print "["
      for (x=1;x<=nw;x++) {
        w=worder[x]
        print "  {"
        printf "    \"wave\": %s,\n", w
        if (w in reason) printf "    \"reason\": \"%s\",\n", reason[w]
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

# --- a ticket's TRANSITIVE declared dependencies (space-separated) -----------
# The reason string must never claim a dependency the graph does not have, so
# every "it depends on X" clause is checked against this.
ticket_dep_closure() { # table-file ticket-id
  awk -F'\t' -v want="$2" '
    { order[++n]=$1; deps[$1]=$5 }
    END {
      nd=split(deps[want], d, " ")
      for (i=1;i<=nd;i++) if (d[i]!="") clo[d[i]]=1
      changed=1
      while (changed) {
        changed=0
        for (k=1;k<=n;k++) {
          m=order[k]; if (!(m in clo)) continue
          nd=split(deps[m], d, " ")
          for (i=1;i<=nd;i++) if (d[i]!="" && !(d[i] in clo)) { clo[d[i]]=1; changed=1 }
        }
      }
      for (k=1;k<=n;k++) if (order[k] in clo) printf "%s ", order[k]
    }
  ' "$1" | sed 's/ *$//'
}

# Tickets placed BEFORE an isolated ticket's wave that come AFTER it in plan
# order — the ones that did NOT build against this infrastructure. Echoes two
# TAB-separated groups: the isolated ticket's own (transitive) DEPENDENCIES,
# which had to build first, and any OTHER ticket the graph forced ahead of it
# (an earlier infra ticket's dependency chain can do this when the plan cannot
# satisfy every barrier at once). The split matters: only the first group may be
# described as a dependency.
wave_preceders() { # wavemap-file table-file ticket-id infra-wave
  local wavemap="$1" table="$2" id="$3" iw="$4" idx all closure deps="" others="" p
  idx="$(awk -F'\t' -v want="$id" '$1==want{print NR; exit}' "$table")"
  [ -n "$idx" ] || { printf '\t'; return 0; }
  all="$(awk -v iw="$iw" -v idx="$idx" -v table="$table" '
    BEGIN { n=0; while ((getline l < table) > 0) { n++; split(l, f, "\t"); ord[f[1]]=n } }
    ($1+0 < iw) { for (i=2; i<=NF; i++) if (ord[$i] > idx) printf "%s ", $i }
  ' "$wavemap" | sed 's/ *$//')"
  closure=" $(ticket_dep_closure "$table" "$id") "
  for p in $all; do
    case "$closure" in
      *" $p "*) deps="${deps:+$deps }$p" ;;
      *)        others="${others:+$others }$p" ;;
    esac
  done
  printf '%s\t%s' "$deps" "$others"
}

# --- the human-readable reason a wave was isolated --------------------------
# Says exactly what the harness KNOWS, and nothing it cannot check. A DECLARED
# flag is stated as fact; a BACKSTOP match is stated as the inference it is, with
# the config file it matched and the missing declaration named. Any ticket that
# built BEFORE this one despite coming later in the plan is named — as a
# DEPENDENCY only when the graph says so, and otherwise as what it actually is.
# $5 set to "lone" words it for a single-ticket plan, where there is no "later".
wave_isolation_reason() { # table-file ticket-id [dep-preceders] [other-preceders] [lone]
  local table="$1" id="$2" deps="${3:-}" others="${4:-}" lone="${5:-}" cls kind evidence head tail
  cls="$(ticket_infra_signal "$table" "$id")" || return 1
  kind="$(printf '%s' "$cls" | cut -f1)"
  evidence="$(printf '%s' "$cls" | cut -f2)"
  if [ "$kind" = "declared" ]; then
    head="$id declares $evidence"
  else
    head="$id has no establishesSharedInfrastructure flag; the harness INFERRED shared build/test infrastructure because its text changes a shared config file ($evidence)"
  fi
  if [ "$lone" = "lone" ]; then
    tail="it is this Mission's only ticket, so it already builds alone"
  else
    tail="isolated into a wave of its own so later tickets build against it"
  fi
  [ -n "$deps" ] && tail="$tail (except $deps, which it depends on and which therefore had to build first)"
  [ -n "$others" ] && tail="$tail; NOTE $others built earlier despite coming later in the plan — the graph forced it ahead, so it did NOT build against this infrastructure"
  printf '%s — %s' "$head" "$tail" | tr -d '"\\' | tr '\n\t' '  '
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

  # S156: classify the INFRASTRUCTURE-ESTABLISHING tickets first — the ticket's
  # DECLARED `establishesSharedInfrastructure` where it has one, else the narrow
  # backstop (see classify_infra_ticket). No LLM call either way. compute_waves
  # isolates each one into a wave of its own, so nothing that will build against
  # the shared build/test config can be its blind sibling. With no such ticket
  # the list is empty and the wave layout is byte-identical to before. The scan
  # ALSO carries the provenance the readout reports — how each call was made.
  local scan; scan="$(mktemp)"
  infra_scan "$table" >"$scan"
  local infra_ids; infra_ids="$(infra_ids_from_scan "$scan")"

  # Build the waves first; a cycle stops us before any issue is created or any
  # state changes (compute_waves has already named the stuck tickets).
  local wavemap; wavemap="$(mktemp)"
  if ! compute_waves "$table" "$infra_ids" >"$wavemap"; then
    rm -f "$table" "$wavemap" "$scan"
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
  local nwaves=0 ntickets=0 nissues=0 nisolated=0 wnum ids id num
  local ISOLATED_NOTE=""
  local ticket_count; ticket_count="$(grep -c . "$table")"
  if [ "$ticket_count" -le 1 ]; then
    # The lone ticket id is the single row's first field; its wave is whatever
    # compute_waves placed it in (always 1 with ≤1 ticket, but read it rather
    # than assume).
    local lone_id lone_wave parent lone_reason=""
    lone_id="$(awk -F'\t' 'NF{print $1; exit}' "$table")"
    lone_wave="$(awk 'NF{print $1; exit}' "$wavemap")"; lone_wave="${lone_wave:-1}"
    parent="$(json_raw "$STATE" githubIssue)"
    nwaves=1; ntickets=1
    # The lone ticket is classified too, so the captain reads the SAME story on a
    # one-ticket plan as on a twelve-ticket one — worded honestly (there is no
    # "later ticket" here to protect).
    lone_reason="$(wave_isolation_reason "$table" "$lone_id" "" "" lone)" || lone_reason=""
    if [ -n "$lone_reason" ]; then
      ISOLATED_NOTE="    wave $lone_wave — $lone_reason
"
      nisolated=1
    fi
    case "$parent" in
      ''|null)
        # Degraded path: no issue on file. Keep TODAY's behaviour — issue: null
        # plus the existing warning. NEVER fabricate an issue; the fast-path is
        # about not creating a REDUNDANT one, never about inventing one.
        printf '%s\t%s\t%s\t%s\n' "$lone_wave" "$lone_id" "" "$lone_reason" >>"$assign"
        RELABEL_NOTE="  ⚠ no githubIssue on file — wrote issue: null for $lone_id (local-only mission)."
        ;;
      *)
        # Reuse the Mission's own issue; open NO sub-issue (nissues stays 0).
        printf '%s\t%s\t%s\t%s\n' "$lone_wave" "$lone_id" "$parent" "$lone_reason" >>"$assign"
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
      # S156: a wave holding exactly ONE ticket that is infrastructure-
      # establishing was ISOLATED by the barrier — say so, in waves.json and in
      # the readout, so a one-ticket wave explains itself. Any other wave gets
      # no reason at all (additive-absent).
      local wave_reason="" preceders="" pre_deps="" pre_other=""
      if [ "$(printf '%s\n' $ids | grep -c .)" = "1" ]; then
        # Tickets that built BEFORE this one despite coming later in the plan,
        # split by whether the GRAPH actually makes them its dependencies — the
        # reason string may only call the first group dependencies.
        preceders="$(wave_preceders "$wavemap" "$table" "$ids" "$wnum")"
        pre_deps="$(printf '%s' "$preceders" | cut -f1)"
        pre_other="$(printf '%s' "$preceders" | cut -f2)"
        wave_reason="$(wave_isolation_reason "$table" "$ids" "$pre_deps" "$pre_other")" || wave_reason=""
      fi
      if [ -n "$wave_reason" ]; then
        ISOLATED_NOTE="${ISOLATED_NOTE}    wave $wnum — $wave_reason
"
        nisolated=$((nisolated + 1))
      fi
      for id in $ids; do
        ntickets=$((ntickets + 1))
        num="$(create_issue "$id" "$type" "$table")"
        [ -n "$num" ] && nissues=$((nissues + 1))
        printf '%s\t%s\t%s\t%s\n' "$wnum" "$id" "$num" "$wave_reason" >>"$assign"
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

  # --- PROVENANCE (S156 fix round 2) ---------------------------------------
  # ALWAYS reported, on every path including the boring one. Without it the
  # captain cannot tell "the planner decided nothing is infrastructure" from
  # "nobody declared anything and the harness guessed" — and those two states
  # schedule identically while carrying completely different risk. Read off the
  # single infra_scan pass; this is a readout, never a gate.
  local n_true n_false n_inferred n_none n_declared contradictions
  n_true="$(awk -F'\t' '$2=="declared-true"{n++} END{print n+0}' "$scan")"
  n_false="$(awk -F'\t' '$2=="declared-false"{n++} END{print n+0}' "$scan")"
  n_inferred="$(awk -F'\t' '$2=="inferred"{n++} END{print n+0}' "$scan")"
  n_none="$(awk -F'\t' '$2=="none"{n++} END{print n+0}' "$scan")"
  n_declared=$((n_true + n_false))
  # A `false` declaration over text the backstop WOULD have matched. The
  # planner's call wins — we only say so out loud, once per ticket.
  contradictions="$(awk -F'\t' '$2=="declared-false" && $3!="" {
      printf "  %s declares establishesSharedInfrastructure: false, overriding a config-file match (%s) — the plan'"'"'s call wins, so it shares its wave.\n", $1, $3 }' "$scan")"

  rm -f "$table" "$wavemap" "$assign" "$scan"

  echo "SCHEDULE: advanced"
  echo "  Grouped $ntickets ticket(s) into $nwaves wave(s); opened $nissues sub-issue(s)."
  if [ "$n_declared" -eq 0 ]; then
    echo "  ⚠ NO ticket declared establishesSharedInfrastructure — the harness fell back to reading ticket text, which only catches a ticket that NAMES a build/test config file. An infrastructure ticket phrased any other way did NOT get a wave of its own. Ask Plan to declare the field."
  elif [ "$n_declared" -eq "$ticket_count" ]; then
    echo "  Infrastructure: all $ticket_count ticket(s) declared establishesSharedInfrastructure ($n_true true, $n_false false)."
  else
    echo "  Infrastructure: $n_declared of $ticket_count ticket(s) declared establishesSharedInfrastructure ($n_true true, $n_false false); $((n_inferred + n_none)) undeclared, read from ticket text instead ($n_inferred matched a config file)."
  fi
  [ -n "$contradictions" ] && printf '%s\n' "$contradictions"
  if [ "$nisolated" -gt 0 ]; then
    if [ "$ticket_count" -le 1 ]; then
      echo "  Infrastructure ticket (a one-ticket plan has nothing to isolate it from):"
    elif [ "$nisolated" -eq 1 ]; then
      echo "  Isolated 1 infrastructure ticket into a wave of its own:"
    else
      echo "  Isolated $nisolated infrastructure tickets into waves of their own:"
    fi
    printf '%s' "$ISOLATED_NOTE"
  fi
  echo "  Wrote waves.json."
  echo "  Stage:  implement"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Implement stage =======================================================
# Processes the waves from waves.json sequentially; tickets within a wave run in
# parallel. S133: each ticket is built by ONE unified TDD worker (tests + code,
# any order, authored in-tree at the repo's convention); proof runs AFTER
# implementation via the S132 gates (result v2, declared-edits, quality floor,
# flip-flop vs the parent commit). This script owns the mechanical handoffs:
#
#   impl-save-result  --mission <id> --ticket <id> --result <file>
#         The unified worker's output, after the proof gates pass. Validate the
#         v2 shape and persist tickets/<id>/result.json; commit + post-commit
#         verify + green. A passed=false result flags the human.
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

# S133: the old MAX_ATTEMPTS=5 internal-attempts cap is RETIRED — result v2's
# `attempts` is the unified worker's own iteration count, informational and
# uncapped-but-reported. The enforced cap is the 3-session gate-bounce loop
# (MAX_WORKER_TRIES) in cmd_implement_ticket.
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

# --- package_of_relpath: the nearest ancestor dir of a path holding a package.json
# The runner's discovery/config root for a given in-tree path. Walks UP from the
# path (which may itself be a package dir) to the first ancestor with a package.json.
# Echoes a repo-relative dir, or "" (repo root / none). PURE — filesystem read only.
package_of_relpath() { # relpath  [root] → pkg dir rel, or ""
  local d="$1" root="${2:-$REPO_ROOT}"
  while [ -n "$d" ] && [ "$d" != "." ]; do
    [ -f "$root/$d/package.json" ] && { printf '%s' "$d"; return 0; }
    case "$d" in */*) d="${d%/*}" ;; *) d="." ;; esac
  done
  return 0
}

# --- ticket_tests_package: the package a ticket's PLACED tests live in ----------
# S133: a package-SPANNING ticket has an empty ticket_target_package (no single
# package), but its fail-first tests are PLACED co-located in a REAL package (where
# their `./sibling` imports resolve). The gates must run FROM that package so the
# runner resolves in a non-hoisted monorepo — the repo root has no hoisted runner.
# Reads the ticket's test MIRROR (tickets/<id>/tests, whose relpaths equal the
# in-tree relpaths) and walks up from the first test to its package. "" when none.
ticket_tests_package() { # ticket  [root] → pkg dir of the ticket's tests, or ""
  # S133: the ticket's tests are recorded at gate-pass time in proof-tests.sha256
  # (the old tickets/<id>/tests mirror is retired with the standoff).
  local t="$1" root="${2:-$REPO_ROOT}" rel
  rel="$(proof_snapshot_rels "$t" | LC_ALL=C sort | head -1)"
  [ -n "$rel" ] || return 0
  package_of_relpath "$rel" "$root"
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

# === S101/S133 placement machinery: RETIRED (S133) ===========================
# The harness no longer PLACES tests — the unified TDD worker authors them
# in-tree at the repo's own convention itself. test_primary_sibling,
# resolve_sibling_src, import_specs_in, anchor_from_pairs and test_file_anchor_dir
# are deleted with the standoff; detect_test_convention + test_path_for remain
# (they state the placement contract in the declared-setup invitation), and
# common_ancestor_dir remains (it scopes multi-dir retests).

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
# DELETE it afterwards without guessing per-CLI names. The implement-tdd
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

  # MULTI-SESSION TICKETS (worktree mode). A bounced ticket re-enters the SAME
  # worktree with the prior session's commit as HEAD — `_tdd_reject` clears
  # result.json and the output dir, never the tree. Committing naively here would
  # STACK a second commit, and `.commit-sha` (a SINGLE sha, written below) would
  # then name only the last session's slice. The wave-end replay cherry-picks that
  # ONE commit (see cmd_implement: "the parent cherry-picks those in plan order";
  # S133: "the ticket's tests ride in its ONE commit"), so sessions 1..N-1 would be
  # dropped SILENTLY — every gate stays green because every gate runs against this
  # worktree, where the full tree exists. Observed live: a 4-session scaffold
  # ticket landed on the mission branch as a lone package-lock.json, the other 13
  # files gone.
  #
  # So: pin the wave base on the first session, and collapse any prior session
  # commits with a SOFT reset before each later one. A soft reset moves HEAD only
  # — index and worktree are untouched — so the commit below carries the ticket's
  # CUMULATIVE diff vs the base, and the existing single-commit replay lands all
  # of it with no change to the conflict / serial-rebuild paths that already
  # assume one commit per ticket. The single-session path is byte-identical: the
  # base is recorded, no reset fires, and the commit's parent is the base as before.
  if [ -n "${LCARS_TICKET_WORKTREE:-}" ]; then
    local basef; basef="$(ticket_dir "$1")/.commit-base"
    if [ -s "$basef" ]; then
      local wbase; wbase="$(cat "$basef" 2>/dev/null)"
      if [ -n "$wbase" ] && [ "$("$GIT_BIN" rev-parse HEAD 2>/dev/null)" != "$wbase" ]; then
        "$GIT_BIN" reset --soft "$wbase" >/dev/null 2>&1 || :
      fi
    else
      "$GIT_BIN" rev-parse HEAD >"$basef" 2>/dev/null || :
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

# --- S102 commit_locked_tests: RETIRED (S133) --------------------------------
# The separate pre-Implementer locked-test commit is gone with the standoff: the
# unified worker's tests are authored in-tree and land in the ONE ticket commit
# (commit_ticket), riding into the PR alongside the source.

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

# --- S106: multi-stack isolation seam --------------------------------------
# The Implement red gate proves the Test-Writer's suite FAILS-first, scoped to
# ONLY the ticket's tests. The default (js/python) mechanism POINTS the runner at
# a tests dir via $LCARS_TESTS_DIR and discriminates scope-was-honored with an
# EMPTY-dir probe (red_gate_ok). But cargo and go CANNOT be pointed at a dir —
# their tests compile INSIDE the crate/package — so scope must be expressed
# per-runner (`cargo test --test <file>` / `go test -run <pattern>`) and the
# scope-was-honored proof becomes a FILE-ABSENCE probe (rerun the same scoped
# invocation with the staged test removed; a DETECTABLE difference proves the
# runner reacted to the staging — the S85 invariant, per stack). A stack id
# selects the strategy; js/python stay the DEFAULT $LCARS_TESTS_DIR path
# UNCHANGED (byte-for-byte), rust/go are NEW branches. `resolve_stack` reads the
# S105 `stack` config key (env override first, for tests).
resolve_stack() {
  if [ -n "${LCARS_STACK:-}" ]; then printf '%s' "$LCARS_STACK"; return 0; fi
  [ -f "$LCARS_CFG" ] || { printf 'unknown'; return 0; }
  local s; s="$(json_str "$LCARS_CFG" stack)"
  case "$s" in ''|null) printf 'unknown' ;; *) printf '%s' "$s" ;; esac
}

# A NATIVE-isolation stack is one whose runner cannot be pointed at an external
# tests dir (compiled per-crate/package) — it needs the per-runner scoped
# invocation + file-absence probe instead of the $LCARS_TESTS_DIR path.
# (S147: dotnet joins with its OWN case — `dotnet test` is PROJECT-oriented, not
# directory-oriented: it compiles the whole test project, so pointing it at an
# external $LCARS_TESTS_DIR quarantine silently runs the project's own suite (or
# nothing at all). Its scope is expressed as `--filter FullyQualifiedName~…`
# instead. This is NOT a blind widening of rust|go: each stack's semantics were
# checked against the real toolchain before it was added.)
stack_is_native() { case "$(resolve_stack)" in rust|go|ruby|dotnet) return 0 ;; *) return 1 ;; esac }

# (S147/S3: `native_runner_bin` — a stack→binary map — is REMOVED. It never had a
# production caller; the scoped invocations name their own runner inline, and the
# only thing keeping it alive was a test asserting on it. Dead code with
# ceremonial coverage reads as a seam that exists, so it is gone rather than
# wired somewhere it was never needed. tests/stack-dotnet.test.sh 3b guards that
# it stays gone.)

# --- S147: the dotnet scoping primitives -----------------------------------
# native_dotnet_project_for — the TEST PROJECT that encloses a staged file: walk
# UP from the file's directory to the nearest ancestor holding a *.csproj and
# echo that csproj's path RELATIVE TO the leg root. Empty when none encloses it
# — which the caller turns into a legible INCONCLUSIVE (the compiler would never
# see a loose .cs outside a project, so it could only ever collect nothing; the
# S87 in-package lesson, in C# form).
native_dotnet_project_for() { # leg-root relpath → rel csproj path ("" = none)
  local root="$1" d="${2%/*}" f
  [ "$d" = "$2" ] && d=""
  while :; do
    for f in "$root${d:+/$d}"/*.csproj; do
      [ -e "$f" ] && { printf '%s%s' "${d:+$d/}" "${f##*/}"; return 0; }
    done
    [ -n "$d" ] || break
    case "$d" in */*) d="${d%/*}" ;; *) d="" ;; esac
  done
  printf ''
}

# native_dotnet_test_fqns — the FULLY-QUALIFIED test class names a staged .cs
# declares, one per line. VSTest's FullyQualifiedName is `Namespace.Class.Method`
# (OBSERVED via `dotnet test --list-tests`, SDK 10.0.107) — the FILE NAME never
# appears in it, so the filter MUST be built from the declared classes, exactly
# as the go leg builds `-run` from the declared Test funcs.
#
# Two things the first cut got wrong, both proven against the real SDK:
#   • BOM. `dotnet new xunit` writes every .cs with a UTF-8 BOM (EF BB BF)
#     before `namespace X;` — verified with xxd. A `^[[:space:]]*namespace` scan
#     therefore matched NOTHING on a real template file and silently dropped the
#     namespace, collapsing the filter to a bare class name (a CONTAINS match),
#     which let unrelated same-named classes ride along. The BOM is stripped
#     from line 1 here, and CR line endings are stripped from every line.
#   • ONE namespace per file. A file may declare several (sequential or nested
#     braced blocks); taking only the first mis-qualified every class under the
#     rest, so a staged FAILING test in the second namespace was never selected
#     and the leg passed without ever running it. Namespaces are now resolved
#     PER CLASS by tracking brace depth.
#   • ONE MATCH PER LINE. Pattern-matching the `class` keyword once per line
#     (the historical version of this note; see the scanner below)
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS IS STILL A SOURCE SCAN, AND WHY THAT IS NOW SAFE (S147 round 3)
#
# This function produced FOUR silent greens across three rounds (second
# namespace dropped, second class on a line dropped, `record`/`struct` dropped,
# multi-line string desyncing brace depth). We spiked making the SDK
# authoritative instead — `dotnet test <proj> --list-tests` reports the true
# VSTest renderings (records, `Ns.GenCases`1`, `Ns.Outer+Inner`, theory
# expansion) and would get every one of those right by construction. It is NOT
# adopted, for two measured reasons:
#
#   1. It cannot serve the PARENT leg. That leg is SUPPOSED not to compile —
#      that is the flip-flop's proof of red-on-parent — and `--list-tests` on a
#      non-compiling tree exits 1 and discovers ZERO tests (observed).
#   2. `--list-tests` reports FQNs, never SOURCE FILES. Something must still
#      decide which discovered tests belong to the staged file, so a source scan
#      remains in the loop and the "unrecognised declaration keyword ⇒ dropped
#      class" mechanism survives. The one variant that removes the scan
#      entirely — discovering with the staged file present and again with it
#      removed, and diffing — is fully sound but costs TWO EXTRA BUILDS per
#      ticket (4.86s vs 1.82s on a fixture whose build is 1.4s).
#
# So the scan stays, and the SAFETY moves to two structural guards that do not
# depend on it being right (both below, and in flip_flop_gate):
#   GUARD 1  native_scoped_cmd refuses to emit an UNQUALIFIED filter term. A
#            dropped class is a silent green; a bogus extra term is only a
#            zero-collect. The failure direction is always INCONCLUSIVE.
#   GUARD 2  flip_flop_gate cross-checks the tests VSTest actually collected
#            against the count this file DECLARES. A scan that drops a
#            declaration under-runs, and the shortfall parks the ticket.
# A parser bug can therefore cost a false INCONCLUSIVE; it can no longer
# certify a test that never ran.
# ─────────────────────────────────────────────────────────────────────────────
#
#   • (historical) ONE MATCH PER LINE. Pattern-matching the `class` keyword once
#     dropped the SECOND class on a line that declares two — never filtered,
#     never run, still recorded proven. That is the same outcome as the
#     one-namespace bug reached through a different trigger, so the cure is
#     structural rather than another pattern: the file is now SCANNED
#     left-to-right, one token at a time, instead of regex-probed per line.
#
# The scanner walks characters, so it also gets the things a line regex cannot:
# string and CHAR literals are skipped before brace counting (a `'}'` literal
# used to desync the depth tracker and emit a BARE, unqualified term — exactly
# the contains-match collision the dot-terminated filter closed), `//` comments
# end the line only when they are not inside a literal, and `/* … */` comments
# are skipped including across lines (a file of commented-out classes must
# declare NO test class and read INCONCLUSIVE, not conjure phantom targets).
#
# Handles the file-scoped (`namespace X;`), braced (`namespace X { … }`) and
# nested-braced forms, several of each per file or per line; a class with no
# namespace yields the bare name (also the observed FQN shape).
#
# KNOWN LIMITS — recorded deliberately, in two groups.
#
# REFUSED OUTRIGHT (GUARD 1's principle: never emit a term we already know
# cannot work). These used to be emitted-and-hoped-for, with GUARD 2 as the net;
# that was not safe enough, because GUARD 2's aggregate slack can absorb them:
#   • a GENERIC test class — VSTest renders it ``Ns.GenCases`1``, so a
#     `~Ns.GenCases.` term selects nothing;
#   • a test class NESTED inside another type — VSTest renders it
#     `Ns.Outer+Inner`, so neither `~Ns.Inner.` nor `~Ns.Outer.` selects it.
# Either one, IN A FILE THAT DECLARES TESTS ON IT, refuses the whole leg with a
# reason naming the type. Nested/generic HELPER types with no tests are ignored
# entirely — they are routine in C# test files and must not park a good ticket.
# "Declares tests" is answered by the pp-BLIND counter (`nseen`), NOT the floor:
# a bad-shape type whose every attribute sits inside `#if` is still a test class
# the SDK discovers, and asking the pp-aware counter made it invisible to BOTH
# guards. Keep those two counters distinct — that composition was a live silent
# green, not a hypothetical.
#
# The refusal is per-FILE, not per-type: ONE unnameable test type parks the whole
# staged set for that ticket, including the types the filter could have named.
# That is the correct direction — a partial selection reported as proof is the
# exact failure this gate exists to prevent, and there is no honest way to
# certify "these three ran, that one could not" as a pass. A captain reading the
# park message sees the type that caused it; moving that one type to a top-level
# non-generic class clears the whole file.
#
# LEFT TO GUARD 2 (under-select or over-declare; the shortfall parks the ticket):
#   • an ABSTRACT test class is named fine by the scan but never discovered by
#     the SDK, so its declared tests go unrun and the shortfall catches it. This
#     is GUARD 2's remaining LIVE job: eight exotic shapes were probed against
#     `--list-tests` on SDK 10.0.107 — static class, static method, private
#     method, generic method, no-public-ctor, throwing-ctor, ctor-with-args are
#     all DISCOVERED; `abstract` was the ONLY scan-names-but-SDK-skips shape
#     found. Recorded so a future round does not re-derive it.
#   • an INTERFACE-declared test is dropped from the filter (interfaces are not
#     a type keyword here) but its `[Fact]` IS counted by the census, so the
#     shortfall is caught — same family, just rarer.
#   • PREPROCESSOR bodies are not counted at all (see `pp` below), so a test
#     inside an ENABLED `#if NET10_0` under-declares. Under-counting is the safe
#     direction: only a shortfall against the observed count is a defect.
#     NOTE FOR WHOEVER READS THIS NEXT: `#if` / `#else` / `#elif` skip EVERY
#     branch, including the one that really compiles. That is DELIBERATE, not an
#     oversight. Evaluating the conditions to count only the live branch would
#     make the floor exact — and would immediately re-introduce the false-park it
#     replaced, because the harness cannot know the defined symbols of the build
#     (TargetFramework, Debug/Release, custom constants). Do not "fix" it.
#
# The SDK's `--list-tests` renders every one of these correctly and is the fix if
# a real ticket ever needs one of these shapes to actually RUN (see the spike
# note above for why it is not the default).
native_dotnet_scan() { # file → "F<Namespace.Type>" lines, then one "A<count>"
  local f="$1" bom
  [ -f "$f" ] || { printf 'A0\n'; return 0; }
  bom="$(printf '\357\273\277')"
  LC_ALL=C awk -v bom="$bom" '
    function nsprefix(   i, p) {
      if (filens != "") return filens "."
      p = ""
      for (i = 1; i <= depth; i++) if (nsname[i] != "") p = p nsname[i] "."
      return p
    }
    function ident(s, n,   nm) {          # read an identifier at GI, advance GI
      nm = ""
      while (GI <= n && substr(s, GI, 1) ~ /[A-Za-z0-9_]/) { nm = nm substr(s, GI, 1); GI++ }
      return nm
    }
    function skipsp(s, n) { while (GI <= n && substr(s, GI, 1) ~ /[ \t]/) GI++ }
    # The last significant char before `pos` on this line — used to tell a type
    # DECLARATION from a generic CONSTRAINT (`where T : class`), where the same
    # keyword follows a `:` or `,`.
    function prevsig(s, pos,   k, c) {
      k = pos - 1
      while (k >= 1) {
        c = substr(s, k, 1)
        if (c == " " || c == "\t") { k--; continue }
        return c
      }
      return ""
    }
    # Record a type declaration. `bad` marks a shape the --filter CANNOT name:
    # generic (VSTest renders `Ns.C`1`) or nested in another type (`Ns.Outer+In`).
    # A nameable type is emitted now; a bad one is held until its scope closes,
    # and only reported if it turned out to DECLARE TESTS — nested/generic helper
    # types (fixtures, builders, data holders) are routine in C# test files and
    # must never park a good ticket.
    function decl(fq, bad) {
      pendname = fq; pendbad = bad; pendtype = 1
      if (!bad && pp == 0) print "F" fq
    }
    function intype(   i) {
      for (i = 1; i <= depth; i++) if (istype[i]) return 1
      return 0
    }
    # Consume one LINE token by token. `inblock`, `strmode` and `rawq` persist
    # ACROSS lines, so a multi-line /* … */, a verbatim @"…" and a raw """…"""
    # all stay swallowed until they really close.
    function scan(s,   n, c, c2, w, nm, j, r) {
      n = length(s); GI = 1
      while (GI <= n) {
        if (inblock) {                                  # inside /* … */
          j = index(substr(s, GI), "*/")
          if (j == 0) return
          GI = GI + j + 1; inblock = 0
          continue
        }
        if (strmode == "verbatim") {                    # inside @"…"
          while (GI <= n) {
            if (substr(s, GI, 1) == "\"") {
              if (substr(s, GI + 1, 1) == "\"") { GI += 2; continue }  # "" escape
              GI++; strmode = ""; break
            }
            GI++
          }
          if (strmode == "verbatim") return
          continue
        }
        if (strmode == "raw") {                         # inside """…"""
          while (GI <= n) {
            if (substr(s, GI, 1) == "\"") {
              r = 0
              while (GI + r <= n && substr(s, GI + r, 1) == "\"") r++
              GI += r
              if (r >= rawq) { strmode = ""; break }
              continue
            }
            GI++
          }
          if (strmode == "raw") return
          continue
        }
        c = substr(s, GI, 1)
        if (c == "/") {
          c2 = substr(s, GI + 1, 1)
          if (c2 == "/") return                         # line comment
          if (c2 == "*") { inblock = 1; GI += 2; continue }
          GI++; continue
        }
        # `@"…"` / `$@"…"` open a VERBATIM string (may span lines, "" escapes).
        if (c == "@" || c == "$") {
          j = GI; r = 0
          while (j <= n && (substr(s, j, 1) == "@" || substr(s, j, 1) == "$")) {
            if (substr(s, j, 1) == "@") r = 1
            j++
          }
          if (substr(s, j, 1) == "\"" && r) { GI = j + 1; strmode = "verbatim"; continue }
          GI = j; continue
        }
        if (c == "\"") {
          r = 0
          while (GI + r <= n && substr(s, GI + r, 1) == "\"") r++
          if (r >= 3) { rawq = r; GI += r; strmode = "raw"; continue }   # raw string
          GI++
          while (GI <= n) {
            c = substr(s, GI, 1)
            if (c == "\\") { GI += 2; continue }
            if (c == "\"") { GI++; break }
            GI++
          }
          continue
        }
        if (c == "'"'"'") {                             # char literal
          GI++
          while (GI <= n) {
            c = substr(s, GI, 1)
            if (c == "\\") { GI += 2; continue }
            if (c == "'"'"'") { GI++; break }
            GI++
          }
          continue
        }
        if (c == "[") { attr++; GI++; continue }
        if (c == "]") { if (attr > 0) attr--; GI++; continue }
        if (c == "{") {
          depth++
          nsname[depth] = pend; pend = ""
          istype[depth] = pendtype; tname[depth] = pendname
          # The carve-out watermark is the pp-BLIND counter (see nseen).
          tbad[depth] = pendbad; tmark[depth] = nseen
          pendtype = 0; pendname = ""; pendbad = 0
          GI++; continue
        }
        if (c == "}") {
          if (depth > 0) {
            # An unnameable type that actually DECLARED tests is reported here —
            # at scope close, when we know whether its body held any. No `pp`
            # condition: a bad type whose CLOSING BRACE happens to land inside an
            # open `#if` is still a bad type, and suppressing the report there
            # would hide it from both guards.
            if (istype[depth] && tbad[depth] && nseen > tmark[depth])
              print "U" tname[depth]
            nsname[depth] = ""; istype[depth] = 0; tname[depth] = ""; tbad[depth] = 0
            depth--
          }
          GI++; continue
        }
        if (c ~ /[A-Za-z_]/) {
          pc = prevsig(s, GI)
          w = ident(s, n)
          # Inside [ … ]: the TEST-ATTRIBUTE census (guard 2). Only attributes
          # that yield AT LEAST one discovered test are counted — [Fact] and
          # [Test]/[TestMethod] yield exactly one, [Theory] yields one or more.
          # Data-row attributes ([InlineData]/[MemberData]/[TestCase]/[DataRow])
          # are deliberately NOT counted: they can only push the OBSERVED count
          # above the floor, never below it.
          # `pp > 0` = inside a #if block. Its body may or may not compile, so it
          # is NOT counted and NOT emitted. Under-counting is the SAFE direction
          # by design (only a SHORTFALL against the observed count is a defect),
          # whereas over-counting parks a legitimate green run — and `#if DEBUG`
          # / `#if NET8_0` / `#if WINDOWS` around a test is routine C#.
          if (attr > 0) {
            if (w == "Fact" || w == "Theory" || w == "Test" || w == "TestMethod") {
              # TWO counters, deliberately different, because the two questions
              # are different:
              #   nseen — EVERY test attribute, #if or not. Answers "does this
              #     type declare tests?" for the R1 carve-out. It must be
              #     pp-BLIND: a bad-shape type whose every attribute is
              #     #if-guarded is still a test class the SDK will discover
              #     (dotnet test defaults to Debug), and a pp-aware count made
              #     it look test-free — refused by nothing, emitted by nothing,
              #     counted by nothing. Invisible to both guards.
              #   nattr — only what is OUTSIDE #if. The GUARD 2 floor, where
              #     under-counting is the safe direction (R2).
              nseen++
              if (pp == 0) nattr++
            }
            continue
          }
          if (w == "namespace") {
            skipsp(s, n)
            nm = ""
            while (GI <= n && substr(s, GI, 1) ~ /[A-Za-z0-9_.]/) { nm = nm substr(s, GI, 1); GI++ }
            if (nm != "") {
              skipsp(s, n)
              # `namespace X;` is file-scoped; `namespace X {` binds to the
              # next opening brace.
              if (substr(s, GI, 1) == ";") { filens = nm; pend = ""; GI++ }
              else                         { pend = nm }
            }
            continue
          }
          # A TEST TYPE can be declared with any of these. `record` may be
          # followed by `class` or `struct` before the name.
          if (w == "record" || w == "class" || w == "struct") {
            # A generic CONSTRAINT (`where T : class`, `where U : struct`) uses
            # the same keyword but always follows a `:` or `,`. It declares
            # nothing — reading it as a declaration used to emit a bogus term
            # named after whatever came next (e.g. a second `where`).
            if ((w == "class" || w == "struct") && (pc == ":" || pc == ",")) continue
            skipsp(s, n)
            nm = ident(s, n)
            if (w == "record" && (nm == "class" || nm == "struct")) {
              skipsp(s, n); nm = ident(s, n)
            }
            # `where T : class` at a line start has no name after it — nothing.
            if (nm == "") continue
            skipsp(s, n)
            # A `<` here means a GENERIC type: VSTest renders it `Ns.C`1`, which
            # this filter cannot name.
            decl(nsprefix() nm, (substr(s, GI, 1) == "<" || intype()) ? 1 : 0)
            continue
          }
          continue
        }
        GI++
      }
    }
    BEGIN { depth = 0; filens = ""; pend = ""; inblock = 0; strmode = ""
            attr = 0; nattr = 0; nseen = 0; pp = 0
            pendtype = 0; pendname = ""; pendbad = 0 }
    {
      if (NR == 1 && substr($0, 1, 3) == bom) $0 = substr($0, 4)
      sub(/\r$/, "")
      # PREPROCESSOR directives are line-oriented and can never be code. Only
      # honoured outside a block comment / multi-line string, so a `#` at the
      # start of a line INSIDE one of those cannot fake a directive.
      if (inblock == 0 && strmode == "" && $0 ~ /^[ \t]*#/) {
        if      ($0 ~ /^[ \t]*#[ \t]*if/)    pp++
        else if ($0 ~ /^[ \t]*#[ \t]*endif/) { if (pp > 0) pp-- }
        next
      }
      scan($0)
    }
    END { print "A" nattr }
  ' "$f" 2>/dev/null
}

# The declared types, fully qualified — the basis for the --filter terms.
native_dotnet_test_fqns() { # file → one Namespace.Type per line
  native_dotnet_scan "$1" | sed -n 's/^F//p'
}

# Types this file declares that DO declare tests and that the --filter provably
# CANNOT select: generic (`Ns.C`1`) and nested-in-a-type (`Ns.Outer+Inner`).
# The caller refuses to build a command at all when this is non-empty — GUARD 1's
# principle, extended from "no unqualified term" to "no term we already know is
# unselectable". The alternative (emit them and let GUARD 2 catch the shortfall)
# is not safe enough: GUARD 2 compares AGGREGATE sums, and a [Theory] contributes
# 1 to the floor but N to the observed count, so the N-1 slack is a budget a
# dropped class can hide inside — an observed silent green, not a theory.
native_dotnet_unnameable() { # file → one Namespace.Type per line
  native_dotnet_scan "$1" | sed -n 's/^U//p'
}

# GUARD 2's declared-test floor for one staged file: how many tests it promises.
# Sound because each counted attribute yields AT LEAST one discovered test
# (measured against SDK 10.0.107: [Fact] ⇒ 1, [Fact(Skip)] ⇒ 1, [Theory]+2
# InlineData ⇒ 2, [Theory]+MemberData(3) ⇒ 3, [Theory]+MemberData(0) ⇒ 1 failing
# "no data" test). Exact equality would be WRONG — theories expand.
native_dotnet_declared_tests() { # file → integer
  local n
  n="$(native_dotnet_scan "$1" | sed -n 's/^A//p' | tail -1)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# How many tests VSTest actually COLLECTED, summed across every project's
# summary line (a multi-project leg emits one each). 0 when no summary appeared.
proof_dotnet_collected_count() { # runner-output → integer
  printf '%s\n' "$1" \
    | grep -E '^(Passed|Failed|Skipped)! +- +Failed: +[0-9]+, +Passed: +[0-9]+' \
    | sed -E 's/.*Total: +([0-9]+).*/\1/' \
    | awk '{ s += $1 } END { print s + 0 }'
}

# (S133: native_dest_rel — the native staged-test destination mapper — is
# retired with impl-save-tests; the unified worker authors native tests in-tree
# at the stack's own convention itself.)


# The go test-function names a staged file declares — the basis for the `-run`
# pattern that scopes go to ONLY this file's tests (no sibling runs).
native_go_test_funcs() { # file
  grep -Eo '^func[[:space:]]+(Test|Benchmark|Example|Fuzz)[A-Za-z0-9_]*' "$1" 2>/dev/null \
    | awk '{print $2}'
}

# The SCOPED invocation for a native stack: run ONLY the ticket's staged test(s),
# no siblings. Echoes the command string (eval'd from the run dir) or EMPTY when
# no runnable target exists in the staged files (no #[test] / no Test func) — the
# caller then BLOCKS loud (scope cannot be proven). Reads the IN-TREE staged files
# (under $REPO_ROOT) named on stdin, one relpath per line.
native_scoped_cmd() { # stack   (relpaths on stdin)
  local stack="$1" rel stem funcs f names=""
  case "$stack" in
    rust)
      local targets=""
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        # Only a file with a #[test]-style attribute yields a runnable target.
        grep -Eq '#\[[a-z_:]*test' "$REPO_ROOT/$rel" 2>/dev/null || continue
        stem="${rel##*/}"; stem="${stem%.rs}"
        targets="$targets --test $stem"
      done
      [ -n "$targets" ] || { printf ''; return 0; }
      printf 'cargo test%s' "$targets"
      ;;
    go)
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        for f in $(native_go_test_funcs "$REPO_ROOT/$rel"); do
          names="${names:+$names|}$f"
        done
      done
      [ -n "$names" ] || { printf ''; return 0; }
      printf "go test -run '^(%s)\$'" "$names"
      ;;
    ruby)
      # S145: rspec/minitest are scoped by EXPLICIT FILE ARGUMENT — pass ONLY the
      # ticket's staged spec/test file(s), so no sibling suite runs (the S106 per-
      # stack isolation invariant). rspec takes files directly; minitest is driven
      # by requiring each file under `ruby -Itest`. rspec wins when both kinds are
      # staged. Runners are invoked DIRECTLY (no `bundle exec`) so the gate runs
      # offline; a *_spec.rb / *_test.rb name is the runnable-target signal (an
      # empty/no-example file still runs and lands as zero-collect → INCONCLUSIVE).
      local rb_specs="" rb_tests=""
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "${rel##*/}" in
          *_spec.rb) rb_specs="$rb_specs $rel" ;;
          *_test.rb) rb_tests="$rb_tests $rel" ;;
        esac
      done
      if [ -n "$rb_specs" ]; then
        printf 'rspec%s' "$rb_specs"
      elif [ -n "$rb_tests" ]; then
        printf "ruby -Itest -e 'ARGV.each { |f| require File.expand_path(f) }'%s" "$rb_tests"
      else
        printf ''
      fi
      ;;
    dotnet)
      # S147: scope = ONE LEG PER TEST PROJECT —
      #   ( cd <projdir> && dotnet test <proj.csproj> --filter "<OR of FQNs>" )
      # chained so EVERY leg runs and a failure in ANY of them fails the command.
      # Emitted relative to the LEG ROOT (proof_native_run_dir returns the root
      # for dotnet), each leg cd-ing into its own project directory.
      #
      # Why per-project (the D3 defect): taking the project from the FIRST staged
      # .cs while OR-ing the FQNs of ALL of them meant a second test project was
      # never built or run, yet flip-flop.json recorded its file as PROVEN — a
      # staged test that must fail could pass the gate without ever executing.
      # Nothing is ever recorded as proven that was not executed, so a staged
      # file that resolves to NO project, or a project that contributes no
      # runnable class, yields an EMPTY command (the caller renders INCONCLUSIVE)
      # rather than a partial run.
      #
      # Why each filter term ENDS in a `.` (the D2 defect): VSTest's `~` is a
      # CONTAINS match, so `~A.B.Widget` also selects `A.B.WidgetExtra`
      # (OBSERVED: it rode along and failed the leg on SDK 10.0.107). The `=`
      # operator IS exact but matches the FULL `Namespace.Class.Method` name, so
      # it cannot scope a whole class — there is no exact CLASS operator.
      # Appending the method separator makes the CONTAINS match exact at the
      # class boundary: `~A.B.Widget.` selects `A.B.Widget.Case` and excludes
      # `A.B.WidgetExtra.Case` (verified both ways against the real SDK).
      #
      # Sibling tests still COMPILE (the project builds as a unit — that is what
      # makes the staged file visible at all) but are NOT RUN.
      local dn_rels="" dn_projs="" dn_pr dn_dir dn_base dn_filter dn_legs="" fq
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "${rel##*/}" in *.cs) : ;; *) continue ;; esac
        dn_rels="$dn_rels$rel
"
      done
      [ -n "$dn_rels" ] || { printf ''; return 0; }
      # Unique enclosing projects, in first-seen order. ANY unenclosed file
      # aborts the whole construction — never half-prove a staged set.
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        dn_pr="$(native_dotnet_project_for "$REPO_ROOT" "$rel")"
        [ -n "$dn_pr" ] || { printf ''; return 0; }
        printf '%s' "$dn_projs" | grep -Fxq "$dn_pr" && continue
        dn_projs="$dn_projs$dn_pr
"
      done <<DN_RELS
$dn_rels
DN_RELS
      while IFS= read -r dn_pr; do
        [ -n "$dn_pr" ] || continue
        dn_dir="${dn_pr%/*}"; [ "$dn_dir" = "$dn_pr" ] && dn_dir="."
        dn_base="${dn_pr##*/}"
        dn_filter=""
        while IFS= read -r rel; do
          [ -n "$rel" ] || continue
          [ "$(native_dotnet_project_for "$REPO_ROOT" "$rel")" = "$dn_pr" ] || continue
          # GUARD 1, extended: a staged file that declares TESTS on a shape the
          # filter cannot name (generic / nested-in-a-type) is refused OUTRIGHT.
          # Emitting the terms we CAN name would run a partial selection and call
          # it proof — which is exactly the silent green the Theory-slack exploit
          # produced. Refuse the whole command; the caller renders INCONCLUSIVE.
          [ -n "$(native_dotnet_unnameable "$REPO_ROOT/$rel")" ] && { printf ''; return 0; }
          for fq in $(native_dotnet_test_fqns "$REPO_ROOT/$rel"); do
            # GUARD 1: never emit an UNQUALIFIED term. A bare `~Widget.` is a
            # CONTAINS match against every namespace in the assembly, so a
            # scanner bug that loses the namespace turns into a ride-along on
            # somebody else's test — the exact shape the dot-terminated,
            # namespace-qualified filter closed. Refusing to build the command
            # makes that INCONCLUSIVE instead: dropping a class is a silent
            # green, an extra term is only a zero-collect, so the failure
            # direction must always be inconclusive, never pass.
            case "$fq" in *.*) : ;; *) printf ''; return 0 ;; esac
            dn_filter="${dn_filter:+$dn_filter|}FullyQualifiedName~$fq."
          done
        done <<DN_R2
$dn_rels
DN_R2
        # A project whose staged files declare no class cannot be scoped at all —
        # running the OTHER projects would report its files as proven.
        [ -n "$dn_filter" ] || { printf ''; return 0; }
        dn_legs="$dn_legs( cd \"$dn_dir\" && dotnet test \"$dn_base\" --filter \"$dn_filter\" ) || _lq=\$?; "
      done <<DN_PROJS
$dn_projs
DN_PROJS
      [ -n "$dn_legs" ] || { printf ''; return 0; }
      printf '_lq=0; %sexit $_lq' "$dn_legs"
      ;;
    *) printf '' ;;
  esac
}

# The honest reason a native stack could NOT construct a scoped invocation —
# rendered as the leg's INCONCLUSIVE message (never a green, never a raw
# toolchain trace). rust/go/ruby keep their pre-147 wording byte-for-byte; only
# dotnet, whose failure has two genuinely different causes, discriminates.
native_no_target_reason() { # stack leg-root rels(newline or single) → message
  case "$1" in
    dotnet)
      # Name the file that actually blocked the construction — with staged files
      # spanning several projects, the FIRST one is often fine and a LATER one is
      # the reason there is no runnable scope.
      local dn_rel dn_orphan=""
      while IFS= read -r dn_rel; do
        [ -n "$dn_rel" ] || continue
        case "${dn_rel##*/}" in *.cs) : ;; *) continue ;; esac
        if [ -z "$(native_dotnet_project_for "$2" "$dn_rel")" ]; then
          dn_orphan="$dn_rel"; break
        fi
      done <<DN_NTR
$3
DN_NTR
      # GUARD 1's own reasons: a declared type that could not be namespace-
      # qualified, or one whose SHAPE the filter cannot name at all. Each is
      # distinct from "no test class" so the readout says what to change.
      local dn_bare="" dn_fq dn_unname=""
      while IFS= read -r dn_rel; do
        [ -n "$dn_rel" ] || continue
        case "${dn_rel##*/}" in *.cs) : ;; *) continue ;; esac
        [ -n "$dn_unname" ] || dn_unname="$(native_dotnet_unnameable "$2/$dn_rel" | head -1)"
        for dn_fq in $(native_dotnet_test_fqns "$2/$dn_rel"); do
          case "$dn_fq" in *.*) : ;; *) dn_bare="$dn_fq"; break ;; esac
        done
        [ -n "$dn_bare" ] && break
      done <<DN_BARE
$3
DN_BARE
      if [ -n "$dn_orphan" ]; then
        printf "proof-gate: no .csproj test project encloses the ticket's C# test file %s — dotnet test compiles per PROJECT, so a loose .cs outside one can never be discovered. Move the test inside the test project (a *.csproj referencing Microsoft.NET.Test.Sdk) and re-run." "$dn_orphan"
      elif [ -n "$dn_unname" ]; then
        printf "proof-gate: the ticket's dotnet test type \`%s\` is GENERIC or NESTED inside another type, and VSTest names those \`Ns.Type\`1\` / \`Ns.Outer+Inner\` — shapes this harness cannot select with --filter. Running only the types it CAN name would certify the ticket on tests that never executed, so the whole leg is refused. Move the test into a top-level, non-generic class and re-run." "$dn_unname"
      elif [ -n "$dn_bare" ]; then
        printf "proof-gate: the ticket's dotnet test type \`%s\` has no namespace, so the scoped invocation could only be built as an unqualified substring filter — which would also select same-named tests elsewhere in the assembly. Declare the test class inside a namespace and re-run." "$dn_bare"
      else
        printf "proof-gate: the ticket's dotnet test file(s) declare no test class — the --filter scoped invocation cannot be constructed."
      fi
      ;;
    *)
      printf "proof-gate: the ticket's %s test file(s) declare no runnable test target — the scoped invocation cannot be constructed." "$1"
      ;;
  esac
}
# (S133: red_gate_native — the pre-implementation native red gate — is retired
# with the standoff; the flip-flop gate's native legs (proof_scoped_leg_run via
# native_scoped_cmd) carry the per-runner scoping truth now.)

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
      # JS/TS + bundler forms (byte-identical to pre-S104), then S104 GO module
      # resolution. Go's forms are ANCHORED to the compiler's OWN `file.go:LINE:COL:`
      # prefix (the go compiler emits line AND column; the testing package prints a
      # single line number) OR line-start `^go: `, so an assertion that merely QUOTES
      # e.g. "cannot find package" mid-diff can never false-match — mirroring the env
      # arm's line-start discipline. Missing-package is RESOLUTION (a type/syntax
      # error is compile, in the `compile` arm below).
      # S145 RUBY: a load/name resolution failure. `cannot load such file -- ` is
      # ruby's require diagnostic (rspec + minitest both print it, `-- ` separator
      # anchors it so an app string merely mentioning the phrase can't false-fire);
      # `uninitialized constant ` / `NameError:` are ruby's unresolved-symbol reds
      # (a greenfield spec referencing a not-yet-defined class). These count as
      # RESOLUTION (a syntax error is compile, in the arm below).
      printf '%s' 'Cannot find module|ERR_MODULE_NOT_FOUND|ERR_REQUIRE_ESM|ERR_UNSUPPORTED_DIR_IMPORT|Failed to load url|Failed to resolve import|Failed to resolve entry|Does the file exist\?|Rollup failed to resolve|\.go:[0-9]+:[0-9]+: (cannot find package|no required module provides package|cannot find module providing package)|^go: .*cannot find module providing package|cannot load such file -- |uninitialized constant |NameError:' ;;
    compile)
      # JS/TS + Python forms (byte-identical to pre-S104), then S104 RUST / GO / DOTNET
      # / JVM compile failures. Every new arm is ANCHORED the way each toolchain prints
      # its OWN diagnostic — rustc's `^error[E####]` / `^error: could not compile`, the
      # go compiler's `file.go:LINE:COL:` (line+col) prefix, csc's `(line,col): error
      # CS####` + MSBuild's `^Build FAILED`, javac's `file.java:LINE: error:` /
      # `^error: cannot find symbol`, maven's `[ERROR] COMPILATION ERROR`, gradle's
      # `^> Task :compile… FAILED` (compile-scoped, so a `:test FAILED` red is untouched)
      # — so an assertion diff that QUOTES a compile phrase, or a genuine cargo/go/junit
      # assertion red, stays a valid fail-first and never trips this detector.
      # S145 RUBY: the interpreter's own `file.rb:LINE: syntax error,` prefix — a
      # parse failure the ruby/rspec/minitest process prints BEFORE any example
      # runs. Anchored to the `.rb:N:` diagnostic prefix so an app/assertion string
      # containing "syntax error," can never trip it (mirroring the go/dotnet arms).
      printf '%s' 'SyntaxError|Unexpected (token|identifier|end of input|string)|Cannot find module|ERR_MODULE_NOT_FOUND|ERR_REQUIRE_ESM|ERR_UNKNOWN_FILE_EXTENSION|is not defined|ParseError|Parse error|cannot parse|invalid syntax|IndentationError|unexpected EOF|compilation (failed|error)|^error\[E[0-9]+\]|^error: could not compile |\.go:[0-9]+:[0-9]+: (undefined:|syntax error)|\([0-9]+,[0-9]+\): error CS[0-9]+|^Build FAILED|\.java:[0-9]+: error:|^error: cannot find symbol|\[ERROR\] COMPILATION ERROR|^> Task :compile[A-Za-z]* FAILED|\.rb:[0-9]+: syntax error,' ;;
    env)
      # S111: `^npm (error|ERR!) could not determine executable to run` is npx's
      # own no-binary diagnostic (`npx vitest` in a package without vitest) —
      # anchored to npm's line-start prefix so an assertion QUOTING the phrase
      # mid-line can never match.
      printf '%s' '^(/[^: ]*/)?(sh|bash|zsh|dash|ash|ksh|env)(\[[0-9]+\])?:.*not found|^(vitest|jest|mocha|pytest|ts-node|tsx|deno|bun|npm|npx|pnpm|yarn|node):.*not found|^npm (error|ERR!) could not determine executable to run|ERR_PNPM_|node_modules.*(missing|not found|No such)|Cannot find module.*node_modules|WARN.*node_modules|ModuleNotFoundError|No module named|: Permission denied$|: cannot execute|cannot execute binary file|^env: .+: No such file or directory|No such file or directory.*(venv|virtualenv|/bin/activate|/bin/python)|source[[:space:]].*/activate' ;;
    assertion)
      # A GENUINE assertion red (the runner started, tests ran, an assertion FAILED)
      # — common vitest/jest/node/pytest phrasings. Classify-only: it never runs
      # against the gate, so it can never accept a red the gate would reject.
      # S104: cargo/go assertion phrasings appended for legibility (classify-only —
      # this arm never feeds a red-gate verdict, so it cannot accept a red the gate
      # would reject; it only lets classify_impl_failure NAME a genuine cross-stack
      # assertion red instead of the generic over-broad-slice).
      # S145 RUBY (classify-only): rspec's `Failure/Error:` marker + its `Failed
      # examples:` footer; minitest's `  N) Failure:` / `N) Error:` block; a
      # summary line naming a NON-ZERO failure/error count (`[1-9][0-9]* failures?`
      # — the `[1-9]` guard means a healthy `0 failures` pass line never matches);
      # and minitest's `Expectation failed`.
      # S147 DOTNET (classify-only): the three .NET frameworks, each anchored the
      # way the runner ACTUALLY prints it (all four forms captured from SDK
      # 10.0.107 in-session, never copied from a doc):
      #  • `^Failed! +- +Failed: +[1-9]` — VSTest's summary line, emitted by
      #    xUnit, NUnit AND MSTest alike. The `[1-9]` guard means the healthy
      #    `Failed:     0` summary of a PASSING run can never match, and the
      #    line-start anchor keeps a quoted copy inside app output from firing.
      #  • `^\[xUnit\.net .*\[FAIL\]` — xUnit's own diagnostic line for a FAILING
      #    case. Anchored on the `[FAIL]` form, NOT the bare `[xUnit.net ` prefix:
      #    xUnit prints the SAME prefix for `[SKIP]`, so the prefix alone made a
      #    fully GREEN run that merely skipped a case classify as a test failure
      #    (`… MixedCases.SkipMe [SKIP]` under a `Passed!` summary).
      #  • `Assert\.[A-Za-z]+\(\) Failure` (xUnit: `Assert.Equal() Failure:`) and
      #    `Assert\.[A-Za-z]+ failed\.` (MSTest: `Assert.AreEqual failed.`),
      #    anchored to the runner's own leading indentation.
      #  • `^[[:space:]]+But was:` — NUnit's constraint-failure second line.
      printf '%s' 'AssertionError|assert(ion)?[[:space:]_-]*(error|failed)|expected .+ (to|toBe|toEqual|to be|to equal|to have|to contain|to match)|[0-9]+ (failed|failing)|Tests?:.*(failed|fail)|✗|✕|●[[:space:]]|^[[:space:]]*FAIL[[:space:]]|panicked at|--- FAIL:|test result: FAILED|Failure/Error|Failed examples:|[0-9]+\) (Failure|Error):|[1-9][0-9]* (failures|errors)\b|Expectation failed|^Failed! +- +Failed: +[1-9]|^\[xUnit\.net .*\[FAIL\]|^[[:space:]]+Assert\.[A-Za-z]+\(\) Failure|^[[:space:]]+Assert\.[A-Za-z]+ failed\.|^[[:space:]]+But was:[[:space:]]' ;;
    zerotests)
      # S99 — the runner FINISHED but collected/ran ZERO tests. CLASSIFY-ONLY (the
      # self-smoke's zero-tests verdict + classify_impl_failure); NEVER consulted by
      # red_gate_ok's verdicts. TIGHT on purpose: it must NOT match a healthy red
      # suite that happens to print "0 passed" — only the runner's own "no tests
      # collected / ran" phrasings.
      # S145 RUBY: rspec's `0 examples, 0 failures` and minitest's `0 runs, 0
      # assertions`. TWO hazards are anchored out:
      #  • the S106 SUBSTRING hazard — a healthy `10 examples`/`10 runs` CONTAINS
      #    `0 examples`/`0 runs`; the `(^|[^0-9])` guard requires the count to be a
      #    STANDALONE zero, so a 10-example suite is never flagged.
      #  • rspec ALSO prints `0 examples, 0 failures, N error occurred…` on a
      #    LoadError (a legitimate greenfield fail-on-parent, exit 1). The `$`
      #    end-anchor on `0 failures` matches ONLY the true-zero summary line, NOT
      #    the load-error line (which has `, N error…` after it) — so a real red is
      #    never swallowed as zero-collect. `No examples found` is deliberately NOT
      #    matched for the same reason (rspec prints it on a LoadError too).
      # S147 DOTNET — the open silent-green trap, closed. THREE phrasings, all
      # OBSERVED on SDK 10.0.107, all exiting **0**:
      #  • `--filter` matched nothing → "No test matches the given testcase
      #    filter `…` in <dll>";
      #  • a test project with no test methods → "No test is available in
      #    <dll>. Make sure that test discoverer & executors are registered…";
      #  • every discovered case SKIPPED (`[Fact(Skip="…")]`) → VSTest's summary
      #    "Skipped! - Failed:     0, Passed:     0, Skipped:     1, Total: 1…".
      #    This third one prints NEITHER "no test" phrase — the tests exist and
      #    were discovered, they just never EXECUTED — so it was the remaining
      #    dotnet green-on-nothing hole (rust's `#[ignore]` equivalent,
      #    `test result: ok. 0 passed`, was already in the family). The arm keys
      #    on the NUMBERS, not the banner word: zero failed AND zero passed on a
      #    VSTest summary line = nothing ran. A mixed run (`Passed: 1, Skipped:
      #    1`) really did execute a test and stays a legitimate pass.
      # ANCHORING (S4, corrected): these are anchored at COLUMN 0 because that is
      # where VSTest prints them, which is a REAL narrowing — prose or app output
      # that quotes a phrase mid-line cannot fire. It is NOT a guarantee that app
      # output can never fire: a program that prints one of these lines flush at
      # column 0 (a test-runner wrapper echoing its child's output, say) WILL
      # match — exactly the same strength, and the same accepted residual risk,
      # as every other member of this family.
      printf '%s' 'No test files found|No test suite found in|No tests found|no tests ran|Ran 0 tests|collected 0 items|(^|[^0-9])0 examples, 0 failures$|(^|[^0-9])0 runs, 0 assertions|^No test matches the given testcase filter .*\.dll|^No test is available in .*\.dll|^(Passed|Failed|Skipped)! +- +Failed: +0, +Passed: +0,' ;;
    hang)
      # A suite that HUNG and never settled under the hard timeout. CLASSIFY-ONLY
      # (classify_impl_failure at exhaustion); NEVER consulted by a gate verdict.
      # (S133: the flip-flop gate legs now time out and render such a suite
      # INCONCLUSIVE at the gate; this arm defensively names a hang phrasing that
      # still reaches exhaustion.) Anchored to explicit "never settled/finished"
      # phrasing so it cannot false-positive on ordinary runner chatter.
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
# S111: per-specifier EXISTENCE triage for the resolution-failure hint. The S95
# feedback asked the worker to CHOOSE between "emit a stub" (brand-new module)
# and "fix the import path" (existing module) — a weak model chooses wrong
# repeatedly (five identical bounces, live). The harness can decide MECHANICALLY:
# a specifier whose basename matches a real source file gets its actual repo
# location(s) named ("your path is wrong — the file lives HERE"); one with no
# match anywhere is provably brand-new ("you MUST emit the stub"). One line per
# specifier, deterministic, pure filesystem read.
unresolved_specifier_triage() { # repo-root  specifiers(one per line, $2 or stdin)
  local root="$1" specs
  if [ "$#" -gt 1 ]; then specs="$2"; else specs="$(cat)"; fi
  local spec base matches
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    base="${spec##*/}"; base="${base%.*}"
    [ -n "$base" ] || continue
    matches="$(find "$root" -maxdepth 7 \
        \( -path '*/node_modules' -o -path "$root/.git" -o -path '*/dist' -o -path '*/build' \) -prune -o \
        -type f \( -name "$base.ts" -o -name "$base.tsx" -o -name "$base.js" -o -name "$base.jsx" -o -name "$base.mjs" \) -print 2>/dev/null \
      | head -3 | sed "s|^$root/||" | paste -sd' ' -)"
    if [ -n "$matches" ]; then
      printf '%s → the module EXISTS in the repo at: %s — your import PATH is wrong, do NOT stub it; re-author the import to reach that file RELATIVE TO YOUR TEST FILE'\''S OWN location.\n' "$spec" "$matches"
    else
      printf '%s → NO file matching '\''%s'\'' exists anywhere in the repo — this is a brand-new module your ticket creates; you MUST emit the empty stub for it (stubs/%s.*), there is no path fix.\n' "$spec" "$base" "$base"
    fi
  done <<TRIAGE_EOF
$specs
TRIAGE_EOF
}

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
#   2. suite-hang          — the runner's own HANG marker (a suite that never
#      settled under the hard timeout — a never-settling awaited/thenable mock or an
#      infinite async init). Checked BEFORE env so a hang is never mis-read as an
#      unprovisioned runner. (S133: the flip-flop gate legs now also time out and
#      render such a suite INCONCLUSIVE at the gate; this arm is the classifier's
#      defensive name for a hang signature that still reaches exhaustion.)
#   2.5 test-infra-mismatch — S131: a DECLARED TEST SETUP was applied this
#      mission (the caller threads the $MISSION_DIR/test-setup-applied.json
#      marker as the 4th input) AND the runner COLLECTED ZERO tests
#      (rg_signature zerotests): the authored runner config's include and the
#      harness's S101 in-tree placement disagree. Named BEFORE env / over-broad
#      so the captain is pointed at the config/placement trap, never at a
#      scoping problem that does not exist (the live 2026-07-09 misdirection).
#      BOTH conditions required — the flag alone never hijacks a genuine red,
#      hang, or env verdict.
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
classify_impl_failure() { # runner_out  worker_out  files_written  [setup_applied]
  local runner_out="${1:-}" worker_out="${2:-}" files_written="${3:-}" setup_applied="${4:-}"
  local has_files=no has_runner=no has_worker=no
  [ -n "$(printf '%s' "$files_written" | tr -d '[:space:]')" ] && has_files=yes
  [ -n "$(printf '%s' "$runner_out"    | tr -d '[:space:]')" ] && has_runner=yes
  [ -n "$(printf '%s' "$worker_out"    | tr -d '[:space:]')" ] && has_worker=yes

  # 1. empty-worker-output — nothing produced at all.
  if [ "$has_files" = no ] && [ "$has_runner" = no ] && [ "$has_worker" = no ]; then
    printf 'empty-worker-output'; return 0
  fi

  # 2. suite-hang — the runner's suite never settled under the hard timeout (a
  # never-settling awaited/thenable mock or an infinite async init). Recognised from
  # the runner's own captured marker so an EXHAUSTED ticket names the hang instead of
  # a generic over-broad slice. Checked before env so a hang is never mis-read as an
  # unprovisioned runner. (S133: the flip-flop gate legs also time out at the gate.)
  if printf '%s' "$runner_out" | grep -Eq "$(rg_signature hang)"; then
    printf 'suite-hang'; return 0
  fi

  # 2.5. test-infra-mismatch (S131) — a declared setup was applied this mission AND
  # the runner collected ZERO tests: the authored config's include never matched
  # the harness-placed in-tree test. Checked after hang (a hang is a hang) and
  # before env/over-broad, so the exhaustion names the include/placement trap
  # instead of a scoping problem that does not exist.
  if [ -n "$setup_applied" ] \
     && printf '%s' "$runner_out" | grep -Eq "$(rg_signature zerotests)"; then
    printf 'test-infra-mismatch'; return 0
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
    test-infra-mismatch)
      # S131: name the PACKAGE from the mission's applied-setup marker when readable.
      local _tim_pkg=""
      [ -n "${MISSION_DIR:-}" ] && [ -f "$MISSION_DIR/test-setup-applied.json" ] \
        && _tim_pkg="$(json_str "$MISSION_DIR/test-setup-applied.json" package)"
      printf "test-infra mismatch (a declared test setup was applied%s but its runner config never collected the harness-placed test — the config's include and the in-tree test placement must agree; NOT a scoping problem)" "${_tim_pkg:+ in '$_tim_pkg'}" ;;
    empty-worker-output)        printf 'empty worker output (the worker produced no file and no output — likely a transient CLI failure, not a code problem)' ;;
    suite-hang)                 printf 'suite hang (the suite never settled under the hard timeout — likely an awaited / thenable mock or an infinite async init)' ;;
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

# --- GUARDRAIL 1 (pre-implementation red gate): RETIRED (S133) ---------------
# red_gate_ok — the BUG-007 fail-first gate over a quarantined/in-place suite,
# with the empty-dir scope probe — is deleted with the standoff. Fail-first is
# now proven POST-implementation by the flip-flop gate (green-on-tip +
# red-on-parent, S132), which reuses the same failure detectors below.

# --- S111: runner PREFLIGHT + the env-cannot-test park ----------------------
# runner_preflight_env_failure probes whether the configured testCommand can
# LAUNCH at all in a given dir — the same empty-quarantine invocation as the red
# gate's probe, classified with the same env-failure signatures. Run BEFORE the
# first Test-Writer spawn so a runner-less package (S110 example-game: `npx
# vitest` → 127) parks the mission with a precise question and ZERO worker
# spends, instead of three retries blamed on the slice. Returns 0 ONLY when the
# runner provably cannot launch (rc!=0 AND an env signature); a healthy runner,
# an empty testCommand (the documented no-runner degradation elsewhere), or the
# kill-switch ($LCARS_RUNNER_PREFLIGHT=0) all return 1 = "do not block".
# Captures the probe output in $PREFLIGHT_OUT for the escalation text.
PREFLIGHT_OUT=""
runner_preflight_env_failure() { # run-dir → 0 iff the runner cannot launch there
  local run_dir="$1" cmd rc=0
  PREFLIGHT_OUT=""
  [ "${LCARS_RUNNER_PREFLIGHT:-1}" != "0" ] || return 1
  cmd="$(resolve_test_cmd)"
  [ -n "$cmd" ] || return 1
  [ -d "$run_dir" ] || return 1
  local empty; empty="$(mktemp -d)"
  PREFLIGHT_OUT="$(cd "$run_dir" && LCARS_TESTS_DIR="$empty" bash -c "$cmd" 2>&1)" || rc=$?
  rm -rf "$empty"
  [ "$rc" -ne 0 ] || return 1
  red_gate_env_failure "$PREFLIGHT_OUT"
}

# --- worktree_setup_configured: is a worktreeSetupCommand declared? -----------
# 0 iff the captain declared a worktree provisioning command (env override or the
# repo config). Mirrors provision_worktree's own resolution. Used to decide whether
# a dead-runner preflight can self-heal by RE-APPLYING that declared command.
worktree_setup_configured() { # → 0 if a worktreeSetupCommand is set, else 1
  [ -n "${LCARS_WORKTREE_SETUP_CMD:-}" ] && return 0
  [ -n "${LCARS_CFG:-}" ] && [ -f "$LCARS_CFG" ] || return 1
  local c; c="$(json_str "$LCARS_CFG" worktreeSetupCommand)"
  case "$c" in ''|null) return 1 ;; *) return 0 ;; esac
}

# --- preflight_runner_or_heal: probe the runner, SELF-HEAL once before failing --
# The S133 env self-heal. A configured `worktreeSetupCommand` that silently didn't
# take (a partial `ln`, a transient miss — the loop returns 0 either way, so
# provision_worktree emits no failure) leaves the runner DEAD in the worktree, and
# the ticket would park at an un-answerable human gate (answering can't provision a
# runner, so it re-parks). Before escalating: if this is a worktree build with a
# declared setup command, RE-APPLY that command ONCE and re-probe. A transient miss
# then clears itself; only a runner that STILL cannot launch after honestly
# re-applying the captain's OWN provisioning escalates (a real env decision). This
# INVENTS nothing — it re-runs only the declared command. Sets PREFLIGHT_HEALED to
# `ok` (launched first try) or `healed` (recovered by the re-apply). Returns 0 when
# the runner can launch (caller proceeds), 1 when it still cannot (caller escalates).
preflight_runner_or_heal() { # run-dir → 0 runner-ok, 1 still-dead
  local pf_dir="$1"
  PREFLIGHT_HEALED=ok
  runner_preflight_env_failure "$pf_dir" || return 0     # runner launches → proceed
  # A worktree build with a declared setup is the only self-healable case.
  [ -n "${LCARS_TICKET_WORKTREE:-}" ] && worktree_setup_configured || return 1
  # RETRY WITH BACKOFF: the dead runner can be a TRANSIENT worktree-lifecycle race
  # — a prior ticket's worktree being torn down as this one provisions momentarily
  # leaves node_modules half-linked (observed live: bug lcars-20260713-003
  # re-parked when its provisioning ran ~10s behind the previous bug's teardown,
  # while it provisions cleanly in isolation). A single immediate re-apply is too
  # fast to outlast that window, so re-apply the declared command a few times with
  # a short backoff, re-probing each round. Still re-runs ONLY the captain's own
  # command; escalate only if the runner is STILL dead after the last attempt.
  local attempts="${LCARS_PREFLIGHT_HEAL_ATTEMPTS:-3}" backoff="${LCARS_PREFLIGHT_HEAL_BACKOFF:-3}" i=1
  while [ "$i" -le "$attempts" ]; do
    emit_event worktree_reprovision implement \
      "the test runner could not launch at preflight — re-applying worktreeSetupCommand for ${TICKET:-?} (attempt $i/$attempts) before escalating" \
      "ticket=${TICKET:-?}" "attempt=$i"
    provision_worktree "$LCARS_TICKET_WORKTREE" || :
    if ! runner_preflight_env_failure "$pf_dir"; then
      PREFLIGHT_HEALED=healed
      emit_event worktree_reprovision_ok implement \
        "worktreeSetupCommand re-applied — the runner now launches for ${TICKET:-?} (attempt $i); continuing (no human gate needed)" \
        "ticket=${TICKET:-?}" "attempt=$i"
      return 0
    fi
    [ "$i" -lt "$attempts" ] && [ "$backoff" -gt 0 ] && sleep "$backoff"
    i=$((i + 1))
  done
  return 1                                               # still dead after every re-apply → escalate
}

# Can this repo demonstrably run tests OUTSIDE the target package? The oracle
# that decides invite-vs-park for a dead-runner package. Two arms, both cheap:
#   1. the repo-root probe launches a runner (single-package repos, hoisted bins)
#   2. any SIBLING package.json declares a known runner (the pnpm-monorepo
#      reality: the workspace ROOT often has no runner in .bin while sibling
#      packages test fine — a root probe alone wrongly reads "dead everywhere")
repo_tests_elsewhere() { # target-pkg-rel → 0 if tests provably run elsewhere
  local pkg="$1"
  if ! runner_preflight_env_failure "$REPO_ROOT"; then return 0; fi
  # NB: the .git exclusion must be ANCHORED at $REPO_ROOT — a per-ticket
  # worktree lives UNDER the clone's .git/lcars/, so a bare '*/.git/*' filter
  # would exclude EVERY file of the worktree and blind the scan (caught live
  # in the S111 proof drive).
  local pj rel
  while IFS= read -r pj; do
    rel="${pj#"$REPO_ROOT"/}"
    [ "$rel" = "package.json" ] && continue
    case "$rel" in "$pkg"/*) continue ;; esac
    grep -Eq '"(vitest|jest|mocha|ava|tap|playwright)"' "$pj" 2>/dev/null && return 0
  done < <(find "$REPO_ROOT" -maxdepth 4 -name package.json \
             -not -path '*/node_modules/*' -not -path "$REPO_ROOT/.git/*" 2>/dev/null)
  return 1
}

# Park the mission awaiting-human because the test environment cannot run ANY
# test for this ticket — the same gate shape as the 5-attempt flag (pending.json
# + awaitingHuman + label overlay), with the BUG-027 structured fields so the
# viewscreen renders a legible card. EXITS 0: the parent driver routes the park
# via the awaitingHuman flag exactly like a flagged ticket.
impl_park_env_cannot_test() { # ticket  reason-text
  local t="$1" reason="$2"
  local q; q="$(mktemp)"
  printf '%s\n' "$reason" >"$q"
  LCARS_PENDING_HUMAN_SUMMARY="The code this mission touches has no working way to run tests, so the fail-first TDD gate cannot run. Add a test runner there, point LCARS at one, or retarget the mission." \
  LCARS_PENDING_ESCALATION_TYPE="cap" \
  LCARS_PENDING_TECHNICAL_DETAIL="$reason" \
    write_pending "$q" "implement"
  rm -f "$q"
  state_set_raw awaitingHuman true
  state_set_str pendingQuestion "Ticket $t is blocked: the test runner cannot run where this ticket builds — needs a human (add a runner / fix provisioning / retarget)."
  gh_relabel "lcars:awaiting-human" ""
  emit_event ticket_env_cannot_test implement \
    "ticket $t parked: the test environment cannot run any tests (no runner in the target package, or unprovisioned)" \
    "ticket=$t" "category=env-cannot-test"
  echo "IMPLEMENT: environment cannot run tests — $t parked (awaiting-human)."
  echo "  No Test-Writer retry can conjure a test runner; this needs a human call."
  echo "  Resolve with \`lcars respond $MISSION_ID\`."
  exit 0
}

# === S111 Phase 3′: EVIDENCE-GATED DECLARED TEST SETUP ======================
# When the preflight proves the ticket's target package cannot run tests while
# the repo root can, the Test Writer is INVITED to DECLARE the missing infra:
# a `setup/` scratch dir of NEW package-relative files + `test-setup.json`
# naming {package, gap, installCommand}. The HARNESS applies it (never the
# worker), the gates verify it via the honest 127→red transition, and a green
# ticket records the verified facts to the repo test landscape. Hard rules:
#   • evidence-gated — no observed env failure, no application (attempt-1 naked)
#   • ADD-only — never overwrite an existing file, never anything under src/
#   • bounded — ≤4 files, ≤20KB each, installCommand must be a package-manager
#     invocation (pnpm/npm/yarn/bun; $LCARS_SETUP_INSTALL_ALLOW_RE overrides)
SETUP_NOTE=""
apply_declared_setup() { # manifest-file  setup-dir  pkg-rel → 0 applied, 1 rejected
  local mf="$1" sdir="$2" pkg="$3"
  SETUP_NOTE=""
  local mpkg gap icmd
  mpkg="$(json_str "$mf" package)"
  gap="$(json_str "$mf" gap)"
  icmd="$(json_str "$mf" installCommand)"
  if [ "$mpkg" != "$pkg" ]; then
    SETUP_NOTE="the manifest names package '$mpkg' but the observed gap is in '${pkg:-<repo root>}' — a declared setup must address the package the evidence is about"
    return 1
  fi
  local allow="${LCARS_SETUP_INSTALL_ALLOW_RE:-^(pnpm|npm|yarn|bun)[[:space:]]}"
  if [ -n "$icmd" ] && ! printf '%s' "$icmd" | grep -Eq "$allow"; then
    SETUP_NOTE="installCommand '$icmd' is not a plain package-manager invocation (must match: $allow)"
    return 1
  fi
  local dest="$REPO_ROOT${pkg:+/$pkg}"
  local n=0 f rel
  if [ -d "$sdir" ]; then
    while IFS= read -r f; do
      rel="${f#"$sdir"/}"
      n=$((n + 1))
      if [ "$n" -gt 4 ]; then SETUP_NOTE="more than 4 setup files declared"; return 1; fi
      if [ "$(wc -c < "$f" | tr -d ' ')" -gt 20000 ]; then SETUP_NOTE="setup file $rel exceeds 20KB"; return 1; fi
      case "/$rel/" in
        *"/../"*)   SETUP_NOTE="path traversal in setup file '$rel'"; return 1 ;;
        *"/src/"*)  SETUP_NOTE="setup file '$rel' targets src/ — declared setup may only add TEST infrastructure, never source"; return 1 ;;
      esac
      if [ -e "$dest/$rel" ]; then
        SETUP_NOTE="setup file '$rel' already exists in the package — declared setup may only ADD files, never modify or loosen existing config"
        return 1
      fi
    done < <(find "$sdir" -type f 2>/dev/null)
  fi
  # Validated — APPLY: copy the new files, then run the install command in the
  # package dir under a hard timeout. The applied files ride the ticket's commit
  # (they are new post-snapshot untracked files), so every downstream gate and
  # the PR see exactly what was provisioned.
  if [ -d "$sdir" ]; then
    while IFS= read -r f; do
      rel="${f#"$sdir"/}"
      case "$rel" in */*) mkdir -p "$dest/${rel%/*}" 2>/dev/null || : ;; esac
      cp "$f" "$dest/$rel"
    done < <(find "$sdir" -type f 2>/dev/null)
  fi
  local irc=0
  if [ -n "$icmd" ]; then
    # Probe-verified: the runner must actually LAUNCH afterwards — exit codes
    # are never trusted (see setup_ensure_runner; shared with the gate reapply).
    setup_ensure_runner "$dest" "$REPO_ROOT" "$icmd" || irc=1
  fi
  [ "$irc" -ne 0 ] && SETUP_NOTE="the runner still cannot launch after the declared install AND a forced symlink-drop + re-link cycle"
  cp "$mf" "$(ticket_dir "$TICKET")/test-setup-applied.json" 2>/dev/null || :
  cp "$mf" "$MISSION_DIR/test-setup-applied.json" 2>/dev/null || :
  emit_event test_setup_applied implement \
    "declared test setup applied to ${pkg:-<root>} — gap: ${gap:-unspecified}; install: ${icmd:-none}${SETUP_NOTE:+ (note: $SETUP_NOTE)}" \
    "ticket=$TICKET"
  return 0
}

# Run a declared install with the pnpm virtual-store SELF-HEAL (caught live,
# S111 001, twice): in a tree whose node_modules were SYMLINKED in by
# worktreeSetupCommand, pnpm refuses to add a dep until the tree's virtual
# store is re-linked — and it cannot re-link THROUGH a symlink. On the pnpm
# complaint: drop ONLY the symlinked node_modules entries (-type l — a real
# dir is never touched), `pnpm install` to rebuild a real tree-local store
# from the lockfile + global store, retry the declared install ONCE. Shared by
# the first application AND every gate-worktree re-apply (the post-commit gate
# hit the unhealed path first, run 5).
setup_install_healed() { # dest-dir  tree-root  install-cmd  outfile → install rc
  local dest="$1" root="$2" icmd="$3" outf="$4" irc=0
  ( cd "$dest" && run_with_hard_timeout "${LCARS_SETUP_INSTALL_TIMEOUT_SECS:-300}" "$outf" bash -c "$icmd" ) || irc=$?
  if [ "$irc" -ne 0 ] && grep -qiE 'virtual store|ERR_PNPM' "$outf"; then
    emit_event test_setup_install_heal implement \
      "declared-setup install hit pnpm's virtual-store guard in $root — dropping the SYMLINKED node_modules, re-linking with 'pnpm install', and retrying once" \
      "ticket=${TICKET:-}"
    ( cd "$root" && find . -maxdepth 5 -name node_modules -type l -exec rm -f {} + 2>/dev/null ) || :
    ( cd "$root" && run_with_hard_timeout "${LCARS_SETUP_INSTALL_TIMEOUT_SECS:-600}" "$outf" bash -c "pnpm install" ) || :
    irc=0
    ( cd "$dest" && run_with_hard_timeout "${LCARS_SETUP_INSTALL_TIMEOUT_SECS:-300}" "$outf" bash -c "$icmd" ) || irc=$?
  fi
  return "$irc"
}

# ENSURE the declared runner actually LAUNCHES in a tree — the ONE helper every
# door uses (first apply, gate-worktree reapply). Exit codes are never trusted:
# after the (failure-healed) install, the runner is PROBED; if it is still dead
# — pnpm's silent "up to date" no-op through symlinked node_modules — the
# relink cycle is FORCED once (drop -type l node_modules only, `pnpm install` a
# real tree-local store, re-run the declared install) and the probe decides.
# Returns 0 iff the runner now launches (or there is nothing to probe with).
setup_ensure_runner() { # dest-dir  tree-root  install-cmd → 0 alive, 1 still dead
  local dest="$1" root="$2" icmd="$3"
  local outf; outf="$(mktemp)"
  setup_install_healed "$dest" "$root" "$icmd" "$outf" || :
  if runner_preflight_env_failure "$dest"; then
    emit_event test_setup_install_heal implement \
      "declared-setup install exited clean but the runner is STILL dead — forcing the symlink-drop + re-link cycle once" \
      "ticket=${TICKET:-}"
    ( cd "$root" && find . -maxdepth 5 -name node_modules -type l -exec rm -f {} + 2>/dev/null ) || :
    ( cd "$root" && run_with_hard_timeout "${LCARS_SETUP_INSTALL_TIMEOUT_SECS:-600}" "$outf" bash -c "pnpm install" ) || :
    ( cd "$dest" && run_with_hard_timeout "${LCARS_SETUP_INSTALL_TIMEOUT_SECS:-300}" "$outf" bash -c "$icmd" ) || :
  fi
  rm -f "$outf"
  ! runner_preflight_env_failure "$dest"
}

# Re-apply a mission's verified/applied setup install in a FRESH gate worktree
# (post-commit / full-suite / reconcile), so those gates judge the same
# provisioned environment the red gate did. The declared FILES already ride the
# committed branch; only the install needs re-running — through the SAME
# probe-verified ensure the first application uses (the post-commit gate hit
# the exit-code-trusting variant live: clean no-op install, dead runner, false
# env-unprovisioned verdict). Best-effort + bounded.
setup_reapply_in_worktree() { # worktree-path
  local wt="$1" rec="${MISSION_DIR:-}/test-setup-applied.json"
  [ -n "${MISSION_DIR:-}" ] && [ -f "$rec" ] || return 0
  local pkg icmd
  pkg="$(json_str "$rec" package)"
  icmd="$(json_str "$rec" installCommand)"
  [ -n "$icmd" ] || return 0
  local allow="${LCARS_SETUP_INSTALL_ALLOW_RE:-^(pnpm|npm|yarn|bun)[[:space:]]}"
  printf '%s' "$icmd" | grep -Eq "$allow" || return 0
  local d="$wt${pkg:+/$pkg}"
  [ -d "$d" ] || return 0
  setup_ensure_runner "$d" "$wt" "$icmd" \
    || emit_event test_setup_reapply_failed implement \
         "declared-setup install left the runner dead in gate worktree $wt even after the forced relink — the gate may misjudge the env" || :
  return 0
}

# On ticket GREEN (post-commit verified), record the setup as a DURABLE, PROVEN
# fact in the repo's test landscape — one file per package under
# .git/lcars/test-landscape/ — so humans and future missions see what testing
# capability this repo actually has and how it got there.
record_test_landscape() {
  local rec="$MISSION_DIR/test-setup-applied.json"
  [ -f "$rec" ] || return 0
  local pkg gap icmd dir key
  pkg="$(json_str "$rec" package)"
  gap="$(json_str "$rec" gap)"
  icmd="$(json_str "$rec" installCommand)"
  dir="$(dirname "$LCARS_CFG")/test-landscape"
  mkdir -p "$dir" 2>/dev/null || return 0
  key="$(printf '%s' "${pkg:-root}" | tr '/' '_')"
  {
    echo '{'
    printf '  "package": "%s",\n' "$(json_escape "${pkg:-}")"
    printf '  "gap": "%s",\n' "$(json_escape "${gap:-}")"
    printf '  "installCommand": "%s",\n' "$(json_escape "${icmd:-}")"
    printf '  "verifiedBy": "%s/%s",\n' "$(json_escape "$MISSION_ID")" "$(json_escape "$TICKET")"
    printf '  "verifiedAt": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
    echo '}'
  } >"$dir/$key.json"
  emit_event test_setup_verified implement \
    "declared test setup VERIFIED green for ${pkg:-root} — recorded to the repo test landscape" \
    "ticket=$TICKET"
  return 0
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

# (S133: the S99 Test-Writer pre-gate self-smoke — self_smoke_verdict /
# self_smoke_reason / test_writer_self_smoke — is retired with the standoff; the
# flip-flop gate's zero-collect check (proof_zero_collected) carries the
# green-on-nothing truth now.)

# --- GUARDRAIL 2 (S133 shape): post-proof test snapshot, declared-edits-aware --
# The old pre-implementation tests.sha256 lifecycle (Test-Writer lock + immutable
# enforcement against the Implementer) is RETIRED with the standoff: the unified
# TDD worker owns its tests, and per-ticket proof is the S132 gates (flip-flop +
# declared-edits). What remains cross-boundary is DRIFT detection: after a
# ticket's gates PASS, the harness records each of its declared test files' hash
# (proof-tests.sha256). Downstream (post-commit / pre-merge) a mismatch is fine
# IFF the editing ticket DECLARED it (its test-edits.json) — an UNDECLARED drift
# of an earlier ticket's committed test still blocks.
sha_of() { # file → hex digest
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else die "no sha256 tool (shasum / sha256sum) available for the test-drift guardrail."; fi
}

# Record "<hash>  <relpath>" for every declared test file of a just-proven ticket
# (newTests ∪ testEdits paths from tickets/<id>/result.json) that exists under
# <tree>. Written ONCE, at gate-pass time, by cmd_implement_ticket.
proof_snapshot_tests() { # ticketId  tree
  local t="$1" tree="$2" out rel
  out="$(ticket_dir "$t")/proof-tests.sha256"
  : >"$out"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$tree/$rel" ] || continue
    printf '%s  %s\n' "$(sha_of "$tree/$rel")" "$rel" >>"$out"
  done < <(proof_result_declared_paths "$(ticket_dir "$t")/result.json" | LC_ALL=C sort -u)
}

# The proven ticket's recorded test relpaths (one per line; empty if none).
proof_snapshot_rels() { # ticketId → relpaths (newline)
  local snap h rel; snap="$(ticket_dir "$1")/proof-tests.sha256"
  [ -f "$snap" ] || return 0
  while read -r h rel; do [ -n "$rel" ] && printf '%s\n' "$rel"; done <"$snap"
}

# Echo every recorded test relpath of <ticket> whose content under <tree> no
# longer matches the proof-time hash (or is missing). Empty output = no drift.
proof_tests_drift() { # ticketId  tree → drifted relpaths (newline)
  local snap h rel tree="$2"; snap="$(ticket_dir "$1")/proof-tests.sha256"
  [ -f "$snap" ] || return 0
  while read -r h rel; do
    [ -n "$rel" ] || continue
    if [ ! -f "$tree/$rel" ] || [ "$(sha_of "$tree/$rel")" != "$h" ]; then
      printf '%s\n' "$rel"
    fi
  done <"$snap"
}

# Union of every ticket's DECLARED test edits (test-edits.json {path} entries)
# for this mission — the allow-list a later ticket's edit of an earlier ticket's
# committed test must appear in. jq-free.
mission_declared_edit_paths() { # → paths (newline)
  local f
  for f in "$MISSION_DIR"/tickets/*/test-edits.json; do
    [ -f "$f" ] || continue
    grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" \
      | sed 's/.*:[[:space:]]*"//; s/"$//'
  done 2>/dev/null | LC_ALL=C sort -u
}

# 0 iff every drifted test of <ticket> under <tree> was DECLARED by some ticket's
# test-edits.json; on failure echoes the undeclared drifted relpaths.
proof_drift_declared_ok() { # ticketId  tree → 0 ok; 1 undeclared (echoes rels)
  local drift declared bad="" rel
  drift="$(proof_tests_drift "$1" "$2")"
  [ -n "$(printf '%s' "$drift" | grep . || true)" ] || return 0
  declared="$(mission_declared_edit_paths)"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    printf '%s\n' "$declared" | grep -Fxq "$rel" || bad="${bad:+$bad
}$rel"
  done <<PDD_EOF
$drift
PDD_EOF
  [ -z "$bad" ] && return 0
  printf '%s\n' "$bad"
  return 1
}

# --- GUARDRAIL 3: test quality (the suite must assert something) ------------
# Light, language-agnostic: reject a suite where no file contains any common
# assertion construct — an empty / zero-assertion / sandbagged contract proves
# nothing. The red gate catches a trivially-PASSING suite; this catches one that
# asserts nothing at all.
suite_has_assertions() { # tests-dir
  # S106: the construct set is language-agnostic — rust (assert!/assert_eq!/panic!)
  # already matches `assert`, but go uses testing.T methods (t.Fatal/t.Error/t.Fail),
  # which none of the JS/py forms cover, so add them (plus rust's panic!). Without
  # this a well-formed go suite would be rejected as "asserts nothing".
  grep -rEiq 'assert|expect|should|\.to[A-Za-z]|require\(|t\.(is|deep|truthy|throws)|check\(|verify\(|t\.(Fatal|Error|Fail|Skip)|panic!' "$1" 2>/dev/null
}

# (S133: GUARDRAIL 3.5 — nonportable_path_in_tests, the Test-Writer absolute-
# path guard — is retired with the standoff; a non-portable test path fails the
# flip-flop parent leg / the clean-worktree gates naturally.)

# ===========================================================================
# S132: PROOF-OF-WORK GATES — STANDALONE (unified-TDD-worker round, S132–135)
# ===========================================================================
# The unified worker retires the Test-Writer/Implementer standoff: ONE worker
# does TDD end-to-end, and proof moves AFTER implementation. The PARENT commit
# is the snapshot (git itself), and fail-on-parent / pass-on-tip is the proof:
#
#   flip_flop_gate       TIP leg green + PARENT leg red on the ticket's own
#                        new/changed tests (scratch worktree at the parent sha,
#                        S87-provisioned, S106-scoped run). S157: a test file that
#                        is NEW at the parent is STAGED IN; one that already
#                        existed there runs the PARENT'S OWN copy, so an honest
#                        repair can be certified (see proof_parent_sources).
#   declared_edits_guard every test-classified path in the diff must be declared
#                        (result.json newTests ∪ testEdits[].path); deletions count.
#   proof_validate_result the v2 result shape (v1 rejects legibly — no dual-shape).
#   proof_quality_floor  suite_has_assertions over the new/changed tests in-tree;
#                        ≥1 new/changed test unless flipFlop=not-applicable.
#
# S133: cmd_implement_ticket now drives these on every ticket (the path HAS
# flipped). They also stay reachable via the *-test dispatch hooks, and they
# REUSE the existing machinery: provision_worktree (S87), native_scoped_cmd +
# intree_scope_for (S106/S87 scoping), suite_collected_zero_tests (S99), the
# red-gate failure detectors (S96 classify arms), emit_event, and the JSON
# helpers. bash-3.2 safe; jq-free (python3 only where json_encode_string already
# depends on it).

# Is a relpath a TEST file? The repo's detected conventions + per-stack patterns
# (*.test.* / *.spec.* / __tests__ for js-ts, test_*.py / *_test.py for python,
# *_test.go for go, tests/*.rs — generalized to any tests|test dir — for rust and
# the "tests" convention repos). A deliberate SUPERSET: over-classifying a helper
# under tests/ only means the worker must declare touching it, never a false pass.
proof_is_test_path() { # relpath → 0 if test-classified
  local p="$1" b; b="${p##*/}"
  # S147 dotnet: `dotnet build` writes GENERATED .cs (AssemblyInfo, GlobalUsings)
  # into obj/ and bin/ INSIDE the test project — i.e. under a `tests/` or
  # `*Tests/` path the rules below would classify as authored tests, which would
  # stage build output into the parent leg as if the ticket had written it.
  # Checked FIRST, and gated on the `.cs` extension so this can never change the
  # classification of any other stack's path (js/python/rust/go/ruby/jvm are
  # byte-identical by construction).
  case "$p" in
    *.cs)
      case "$p" in obj/*|*/obj/*|bin/*|*/bin/*) return 1 ;; esac ;;
  esac
  case "$p" in
    */__tests__/*|__tests__/*)          return 0 ;;
    tests/*|*/tests/*|test/*|*/test/*)  return 0 ;;
    spec/*|*/spec/*)                     return 0 ;;  # S145: ruby rspec layout
  esac
  case "$b" in
    *.test.*|*.spec.*)   return 0 ;;
    test_*.py|*_test.py) return 0 ;;
    *_test.go)           return 0 ;;
    *_spec.rb|*_test.rb) return 0 ;;  # S145: ruby rspec / minitest
  esac
  # S147 dotnet: C# has no `_test.cs` convention — tests live in a project named
  # `<Thing>.Tests` (what `dotnet new xunit` scaffolds) with files like
  # `UnitTest1.cs` / `WidgetTests.cs`. Gated on the `.cs` extension so this arm
  # can NEVER reclassify a path in any other stack (js/python/rust/go/ruby/jvm
  # behaviour is byte-identical by construction).
  case "$p" in
    *.cs)
      case "$p" in *Tests/*|*Test/*|*Tests.*/*) return 0 ;; esac
      case "$b" in
        *Test.cs|*Tests.cs|Test*.cs|*Test[0-9]*.cs|*Tests[0-9]*.cs) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# Every path the tip differs from the parent in: the tracked diff (modifications
# AND deletions) plus untracked files (a not-yet-committed new test still counts).
# --no-renames: git's rename detection would collapse an R100 rename to just the
# NEW path, letting the old test vanish undeclared — surface it as delete+add.
proof_diff_paths() { # parent-sha worktree → one relpath per line (sorted, unique)
  local parent="$1" wt="$2"
  {
    "$GIT_BIN" -C "$wt" diff --no-renames --name-only "$parent" -- 2>/dev/null
    "$GIT_BIN" -C "$wt" ls-files --others --exclude-standard 2>/dev/null
  } | grep . | LC_ALL=C sort -u
}

# S157 (live-drive blocker): is this path something THE HARNESS provisioned into
# the worktree, rather than something the worker wrote?
#
# LCARS's own `worktreeSetupCommand` SYMLINKS the dependency directory into each
# ticket worktree. A `.gitignore` entry of `node_modules/` — with the trailing
# slash, the near-universal convention — is a DIRECTORY-ONLY pattern, and git
# does not apply it to a SYMLINK. So `ls-files --others --exclude-standard`
# reports the link as an untracked path, and the repair-eligibility check read
# the harness's own provisioning as a worker-authored non-test change. Observed
# live on a pnpm monorepo: three symlinks turned a one-line test fix into a
# "mixed diff", and the session only certified because the worker hand-edited
# .git/info/exclude to neutralise an artifact LCARS had created.
#
# THE RULE IS GENERAL, NOT A DEPENDENCY-DIRECTORY LIST: an UNTRACKED SYMLINK in
# the worktree is provisioning, not authorship. A worker writing a test or a
# source file produces a regular file; the harness is the only thing here that
# creates links. That keeps it stack-agnostic — node_modules, .venv, vendor,
# target, whatever a repo's setup command links — with nothing to rot.
#
# WHAT IT DOES NOT COVER, stated plainly: a setup command that COPIES or really
# INSTALLS a dependency tree produces regular files, not links. Those are correctly
# ignored by the same `node_modules/` pattern (it does match directories), so the
# defect does not arise there — but a repo that does not ignore its dependency
# directory at all will still see them, and that is a repo-hygiene problem this
# cannot and should not paper over. A TRACKED symlink is likewise never skipped:
# if a symlink is committed, changing it is a real change to the repo.
proof_is_provisioning_artifact() { # relpath worktree → 0 when harness-provisioned
  local p="$1" wt="$2"
  [ -L "$wt/$p" ] || return 1
  # Tracked ⇒ it is part of the repo and any change to it is the worker's.
  "$GIT_BIN" -C "$wt" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && return 1
  return 0
}

# The diff's TEST-classified paths. mode "existing" keeps only files present in
# the worktree (the runnable set); default "all" includes deletions (the
# declared-edits set — a deleted test is an edit).
proof_test_rels_in_diff() { # parent-sha worktree [existing|all] → relpaths
  local parent="$1" wt="$2" mode="${3:-all}" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    proof_is_test_path "$p" || continue
    if [ "$mode" = existing ] && [ ! -f "$wt/$p" ]; then continue; fi
    printf '%s\n' "$p"
  done < <(proof_diff_paths "$parent" "$wt")
}

# ZERO tests collected/ran on a leg — the S85/S106 green-on-nothing trap,
# INCONCLUSIVE on either leg, never a pass. Extends suite_collected_zero_tests
# (S99, js/py phrasings) with the native runners' own zero phrasings LOCALLY —
# the shared `zerotests` signature is classify-only for the LIVE path and must
# stay byte-identical (this session touches no live verdict).
proof_zero_collected() { # runner-output → 0 if zero tests were collected/ran
  suite_collected_zero_tests "$1" && return 0
  # S147: the dotnet pair rides the SHARED `zerotests` arm above (they are real
  # runner phrasings, useful to the live classifier too), so nothing extra is
  # needed here — go's/cargo's exit-0 forms stay local as before.
  printf '%s' "$1" | grep -Eq 'no tests to run|test result: ok\. 0 passed'
}

# WHAT the leg was doing when the clock ran out (S147 DEFECT-4).
#
# The gate timeout exists to bound a suite that NEVER SETTLES, and the old
# message said exactly that — unconditionally. But a leg can also run out of
# clock while it is still FETCHING OR COMPILING DEPENDENCIES: the first `dotnet
# test` on a machine with a cold NuGet cache downloads its whole package graph
# before a single test runs. Those two are opposite problems with opposite fixes
# (a hang is a bug in the ticket's tests; a slow restore just needs a warmer
# cache or a bigger budget), and blaming the suite for a slow restore is the
# false-park this round exists to avoid.
#
# The discrimination is EVIDENCE-BASED, read off the runner's own captured
# output — never a guess. Three honest states:
#   * it announced restore/download/compile work and never reached test
#     execution  → report the dependency phase;
#   * it reached test execution and then stopped producing  → a hang, as before;
#   * it produced nothing to go on  → say that, and name both possibilities.
# The bound itself is UNCHANGED: the runner is still group-killed at $gsecs, on
# every path. This only changes what the captain is TOLD about the kill.
#
# TWO RULES KEEP IT HONEST (learned the hard way — the first cut broke both):
#
#   1. EXECUTION EVIDENCE WINS, ALWAYS. If anything in the buffer shows a test
#      actually running, this is a hang — no matter what else the buffer holds.
#      The first cut matched a bare `Downloading ` anywhere, so a genuine
#      never-settling test that printed "Downloading rate-table.json from the
#      fixture server" was absolved as a cold-cache restore ("the tests
#      themselves are not implicated") while the SAME buffer carried node's own
#      `✖ … (4874ms)` / `ℹ cancelled 1`. Telling a captain to warm the cache and
#      raise the timeout just makes them wait longer for the same hang. So
#      `started_re` is deliberately BROAD across runners (a per-test duration in
#      parentheses is enough), and it is tested FIRST.
#   2. A DEPENDENCY VERDICT NEEDS A REAL PACKAGE-MANAGER BANNER, AND IT MUST BE
#      THE LAST THING SEEN. The tokens are shaped like what package managers
#      actually print (`Downloading <pkg> <version>`, `go: downloading`,
#      `Compiling <crate> v1.2`), not bare English words an application logs, and
#      they only count in the TAIL — a restore that finished long ago is not what
#      the clock ran out on.
#
# Anything else is UNDETERMINED, and says so. Honest ambiguity is acceptable; a
# confident wrong classification is not.
proof_timeout_cause() { # runner-output → the cause clause
  local out="$1"
  # Evidence that a TEST ACTUALLY RAN, across the runners LCARS drives. Broad on
  # purpose: a false "hang" only costs the captain a second look, whereas a false
  # "cold cache" sends them away from a real bug.
  local started_re='Starting test execution|Test run for |VSTest version|^(Passed|Failed|Skipped)!|test result:|^[[:space:]]*running [0-9]+ test|^=== RUN|^--- (PASS|FAIL|SKIP)|^(ok|FAIL|PASS)[[:space:]]|[0-9]+ examples?, [0-9]+ failure|^[[:space:]]*ℹ (tests|pass|fail|cancelled|suites)|^[[:space:]]*(✔|✖|✓|×|✗)[[:space:]]|^# Subtest|^TAP version|Test Files |^Tests[[:space:]]|^(PASS|FAIL)[[:space:]]|RUN  v|collected [0-9]+ item|test session starts|[0-9]+ (passed|failed|passing|failing)|\([0-9]+(\.[0-9]+)?[[:space:]]*m?s\)'
  # Real package-manager restore banners ONLY — each carries a package/version or
  # a tool-specific prefix, so an application's own "Downloading report.csv" or
  # "Building index" cannot trip it.
  local dep_re='Determining projects to restore|Restoring packages|Restored .*\.(cs|fs|vb)proj|^[[:space:]]*Downloading [^[:space:]]+ [0-9]+\.[0-9]|go: downloading |Updating crates\.io index|^[[:space:]]*Downloaded [0-9]+ crate|^[[:space:]]*Compiling [^[:space:]]+ v[0-9]|^[[:space:]]*Fetching (gem|source|https?://)|^[[:space:]]*Installing [^[:space:]]+ [0-9]+\.[0-9]|Resolving dependencies|added [0-9]+ packages|Bundle complete'

  # RULE 1 — execution evidence anywhere in the buffer settles it.
  if printf '%s' "$out" | grep -Eq "$started_re"; then
    printf 'the suite STARTED running and then stopped producing output — a suite that never settles cannot prove anything. Look for a hang in the tests themselves (an unresolved promise, an awaited mock, a blocked I/O wait); raising LCARS_GATE_TIMEOUT will only make the wait longer.'
    return 0
  fi
  # RULE 2 — a restore banner, and it has to be what the clock ran out ON.
  local tail_lines; tail_lines="$(printf '%s' "$out" | grep . | tail -5)"
  if printf '%s' "$tail_lines" | grep -Eq "$dep_re"; then
    printf 'the leg was still RESOLVING/BUILDING DEPENDENCIES and never reached test execution — this is a cold-cache first run, NOT a hung suite. Warm the cache once (e.g. run the stack'"'"'s restore/build in the repo) or raise LCARS_GATE_TIMEOUT for this repo; the tests themselves are not implicated.'
    return 0
  fi
  printf 'the leg produced nothing the harness recognised as either test execution or dependency resolution, so the cause is undetermined — it may be a hung suite OR a slow first-run dependency restore. Re-run the recorded command by hand (see this leg'"'"'s "cmd") to see which; raise LCARS_GATE_TIMEOUT if it is simply slow.'
}

# Single-quote a string for safe re-use in a shell (S147 round 2). The recorded
# gate command is meant to be PASTED, so every interpolated path/scope/command
# has to survive spaces, quotes, `$`, backticks and backslashes verbatim. Single
# quotes suppress all expansion; the only character needing care is `'` itself,
# closed and re-opened around an escaped one ('\'').
proof_shq() { # string → '…' safe for a shell
  local s="$1"
  # The quote characters come from ANSI-C literals, NOT from backslash escapes
  # inside a double-quoted replacement: `"${s//\'/\'\\\'\'}"` LOOKS right and is
  # not — bash re-processes the replacement, and the result mangles every
  # apostrophe (a path like /Users/o'brien produced an unpasteable string). With
  # both sides held in plain variables there is no second round of processing.
  local sq=$'\047'                # '
  local rep=$'\047\134\047\047'   # '\''  — close, escaped quote, reopen
  s="${s//$sq/$rep}"
  printf '%s%s%s' "$sq" "$s" "$sq"
}

# GLOB METACHARACTERS IN THE SCOPE (S148 GUARD, generic lane only). Since Node
# 22, `node --test <path>` treats its positional as a GLOB PATTERN, so the
# ABSOLUTE scope — which carries the checkout's own path — is re-interpreted by
# the runner. This is NOT a quoting bug: the shell delivers the right bytes and
# the runner re-globs them, and glob-ESCAPING here would corrupt the path for
# every runner that takes it literally (pytest and rspec both do). Observed on
# node v25.6.1, one directory per character:
#   `*`  EXPANDS across siblings — the leg silently runs test files the ticket
#        never touched. Not merely a false fail: a ride-along in a glob-matched
#        sibling can supply the PARENT leg's red, turning a test-after cheat the
#        gate correctly FAILS into a recorded PASS (constructed and observed).
#   `?`  same expansion, one character wide.
#   `[`  a CLOSED class (`br[a-c]k`) matched a SIBLING instead of the real
#        directory — one test collected, from the wrong repo, with no sign of it.
#   `{`  `{a,b}` brace-expands identically.
#   `\`  is glob-UNESCAPED → "Could not find '<path>'" while the file plainly
#        exists → a false fail on honest work.
# A lone `[` / `{` (unclosed, or no comma) is literal TODAY, but whether it opens
# a class is the runner's own parsing state — so we refuse the OPENER rather than
# re-implement its parser and be silently wrong. Everything else a real machine
# actually has in a path — space, tab, `'`, `"`, `$`, backtick, `;`, `#`, `~`,
# `+`, parens, `&`, `=`, `!`, unicode — is verified LITERAL and must keep running
# (tests O5); each character here is a repo shape LCARS refuses.
proof_scope_glob_char() { # abs-scope → the first glob metachar in it ("" = safe)
  local s="$1" c
  for c in '*' '?' '[' '{' '\'; do
    case "$s" in *"$c"*) printf '%s' "$c"; return 0 ;; esac
  done
  printf ''
}

# Run the ticket's tests SCOPED, per stack, from a given tree root (either the
# tip worktree or the parent scratch worktree). Sets PROOF_LEG_RC + PROOF_LEG_OUT.
# rc 96/97 are local sentinels for "cannot even construct the run" (no
# testCommand / no runnable native target / a scope the runner would re-glob) —
# the caller renders INCONCLUSIVE.
# PROOF_LEG_CMD (S147 DEFECT-2) — the command this leg ACTUALLY executed, as a
# reader could paste it into a shell. rc + a 20-line tail can never show whether
# the run was scoped: on dotnet the `--filter` and the unscoped invocation print
# BYTE-IDENTICAL output, so a captain auditing flip-flop.json had no way to tell
# the gate really narrowed the run and had to reconstruct the command by hand.
# Recording it makes the gate self-evidencing. It is the real string (filter
# terms, per-project `cd` legs, the LCARS_TESTS_DIR scope and the cwd), NOT a
# label — a pretty summary would re-open exactly the gap this closes.
PROOF_LEG_RC=0; PROOF_LEG_OUT=""; PROOF_LEG_CMD=""
proof_scoped_leg_run() { # leg-root rels(newline)
  local root="$1" rels="$2" first cmd run_dir rc=0 out
  PROOF_LEG_RC=0; PROOF_LEG_OUT=""; PROOF_LEG_CMD=""
  first="$(printf '%s\n' "$rels" | grep . | head -1)"
  local stack; stack="$(resolve_stack)"
  # S133/DEFECT-2: both flip-flop legs run under a PORTABLE hard timeout so a
  # suite that never settles (the awaited-thenable-mock hang class the retired
  # self-smoke used to catch) is rendered INCONCLUSIVE — sentinel 98 — instead
  # of silently hanging the ticket build. run_with_hard_timeout group-kills the
  # runner (perl setsid) so no forked child (vitest/jest pool) survives.
  local gsecs="${LCARS_GATE_TIMEOUT:-120}"
  case "$gsecs" in ''|*[!0-9]*) gsecs=120 ;; esac
  local gof; gof="$(mktemp "${TMPDIR:-/tmp}/lcars-ffleg.XXXXXX" 2>/dev/null)" \
    || gof="${MISSION_DIR:-$root}/.ffleg.$$"
  if stack_is_native; then
    # S106 native scoping: cargo test --test <stem> / go test -run '^(funcs)$',
    # built from the staged files AT THIS LEG'S ROOT.
    cmd="$(printf '%s\n' "$rels" | REPO_ROOT="$root" native_scoped_cmd "$stack")"
    if [ -z "$cmd" ]; then
      rm -f "$gof"
      PROOF_LEG_RC=97
      PROOF_LEG_OUT="$(native_no_target_reason "$stack" "$root" "$rels")"
      return 0
    fi
    run_dir="$(proof_native_run_dir "$stack" "$root" "$first")"
    # The native cmd is a self-contained shell string with no dependence on env
    # the gate sets, so `cd <dir> && <cmd>` re-runs faithfully as-is; only the
    # directory needs quoting (a repo path may contain a space).
    PROOF_LEG_CMD="cd $(proof_shq "$run_dir") && $cmd"
    ( cd "$run_dir" && run_with_hard_timeout "$gsecs" "$gof" bash -c "$cmd" ); rc=$?
  else
    # js/py: the S87 dir-scoped run — LCARS_TESTS_DIR points at the single file
    # (or the common ancestor), invoked from the tests' own package.
    cmd="$(resolve_test_cmd)"
    if [ -z "$cmd" ]; then
      rm -f "$gof"
      PROOF_LEG_RC=96
      PROOF_LEG_OUT="proof-gate: no testCommand configured — the harness cannot run the ticket's tests."
      return 0
    fi
    local pkg; pkg="$(package_of_relpath "$first" "$root")"
    run_dir="$root${pkg:+/$pkg}"
    local scope; scope="$(intree_scope_for "$root" "$rels")"
    # S148 GUARD — a scope the runner would re-interpret as a glob PATTERN (see
    # proof_scope_glob_char). Refuse the leg rather than run it: unrun is
    # INCONCLUSIVE, whereas running it is either a mystery red or a widened run
    # whose green (or whose parent-leg red) came from a file the ticket never
    # touched. Native lanes are immune — no repo path enters their command.
    local gch; gch="$(proof_scope_glob_char "$scope")"
    if [ -n "$gch" ]; then
      rm -f "$gof"
      PROOF_LEG_RC=96
      PROOF_LEG_OUT="proof-gate: the path this leg must hand the test runner contains \`$gch\`, which the runner re-interprets as a GLOB PATTERN instead of a literal path (scope: $scope) — the run would either find nothing or silently widen to files the ticket never touched, so it was NOT run. Nothing is wrong with the ticket: it is WHERE the repo lives. Move or rename the checkout to a path free of \` * ? [ { \\ \` and re-run."
      return 0
    fi
    # S148 — WHITESPACE IN THE CHECKOUT PATH. $scope is ABSOLUTE, so it carries
    # the repo's path, and everything on this lane hands it over quoted: the
    # `LCARS_TESTS_DIR="$scope"` assignment below, the proof_shq-quoted record,
    # and (since S148) the SEEDED testCommand's own interpolation of it. Before
    # that last one was quoted, a repo living at `…/sp test` word-split the scope
    # inside the testCommand — the runner got `…/sp` and `test/…`, the TIP leg
    # went red, and the gate FALSE-FAILED honest tickets by location alone.
    #
    # THE SEPARATE BOUND, now GUARDED just below: quoting delivers the scope
    # byte-correct, but the RUNNER may re-interpret it — `node --test <path>`
    # takes its positional as a glob pattern. That is not fixable by quoting or
    # by escaping, so the guard refuses those repo shapes instead of running them.
    # The js/py lane scopes via the LCARS_TESTS_DIR the testCommand interpolates,
    # so the env assignment is PART of the command a reader would have to re-run.
    #
    # IT MUST BE RECORDED AS THE GATE ACTUALLY RUNS IT — `bash -c <cmd>` with the
    # variable in the child's ENVIRONMENT — not as the bare prefix form
    # `LCARS_TESTS_DIR=<scope> <cmd>`. An assignment prefix does NOT affect
    # `$LCARS_TESTS_DIR` references on the same command line: a pasting shell
    # expands them BEFORE the prefix takes effect, to EMPTY, so the runner gets no
    # path and silently runs the WHOLE suite. (On a compound testCommand the
    # prefix binds only to the first element, which is worse still.) That made the
    # artifact assert the OPPOSITE of what the gate did — a scoped green recorded
    # as a command that re-runs red on unrelated tests. Quoting `$cmd` and handing
    # it to `bash -c` is what the line below genuinely executes.
    PROOF_LEG_CMD="cd $(proof_shq "$run_dir") && LCARS_TESTS_DIR=$(proof_shq "$scope") bash -c $(proof_shq "$cmd")"
    ( cd "$run_dir" && LCARS_TESTS_DIR="$scope" run_with_hard_timeout "$gsecs" "$gof" bash -c "$cmd" ); rc=$?
  fi
  out="$(cat "$gof" 2>/dev/null)"; rm -f "$gof"
  if [ "$rc" = 124 ]; then
    PROOF_LEG_RC=98
    PROOF_LEG_OUT="scoped test run exceeded the ${gsecs}s gate timeout (LCARS_GATE_TIMEOUT) and was terminated — $(proof_timeout_cause "$out")
${out}"
    return 0
  fi
  PROOF_LEG_RC="$rc"
  PROOF_LEG_OUT="$out"
}

# The cwd a native scoped invocation must run from: go tests compile in their
# package DIR; cargo runs from the crate root (nearest ancestor Cargo.toml).
proof_native_run_dir() { # stack leg-root first-rel → abs run dir
  local stack="$1" root="$2" rel="$3" d
  d="${rel%/*}"; [ "$d" = "$rel" ] && d=""
  case "$stack" in
    go)   printf '%s%s' "$root" "${d:+/$d}" ;;
    rust)
      while [ -n "$d" ]; do
        [ -f "$root/$d/Cargo.toml" ] && { printf '%s/%s' "$root" "$d"; return 0; }
        case "$d" in */*) d="${d%/*}" ;; *) d="" ;; esac
      done
      printf '%s' "$root" ;;
    # S145: ruby runs from the repo/Gemfile root so `.rspec`, spec_helper, and the
    # test/ load path (`-Itest`) resolve; the staged relpaths stay repo-root-relative.
    ruby) printf '%s' "$root" ;;
    # S147: dotnet runs from the LEG ROOT. Staged files can span SEVERAL test
    # projects, so the scoped command carries one `( cd <projdir> && dotnet test
    # <proj> … )` leg per project — the cwd it needs is the root those relative
    # project dirs are expressed against, not any single project's directory.
    dotnet) printf '%s' "$root" ;;
    *)    printf '%s' "$root" ;;
  esac
}

# Cut the DISPOSABLE parent-leg scratch worktree at the parent sha, provisioned
# via the S87 machinery (worktreeSetupCommand + declared-setup re-apply). Echoes
# its path; empty on failure. Mirrors make_ticket_worktree's prune-and-retry
# self-heal for stale registrations.
proof_parent_scratch() { # tip-worktree parent-sha ticket → scratch path ("" = failed)
  local wt="$1" sha="$2" t="$3" base scratch
  base="${LCARS_PROOF_WT_BASE:-$MISSION_DIR/proof-worktrees}"
  mkdir -p "$base" 2>/dev/null || { printf ''; return 1; }
  scratch="$base/$t-parent"
  "$GIT_BIN" -C "$wt" worktree remove --force "$scratch" >/dev/null 2>&1 || :
  rm -rf "$scratch"
  if ! "$GIT_BIN" -C "$wt" worktree add -q --detach "$scratch" "$sha" >/dev/null 2>&1; then
    "$GIT_BIN" -C "$wt" worktree prune >/dev/null 2>&1 || :
    rm -rf "$scratch"
    "$GIT_BIN" -C "$wt" worktree add -q --detach "$scratch" "$sha" >/dev/null 2>&1 \
      || { rm -rf "$scratch"; printf ''; return 1; }
  fi
  provision_worktree "$scratch" || :
  printf '%s' "$scratch"
}

# Prune the scratch worktree — called on EVERY exit path (pass, fail,
# inconclusive), immediately after the parent leg runs and before any verdict.
proof_prune_scratch() { # tip-worktree scratch
  [ -n "${2:-}" ] || return 0
  "$GIT_BIN" -C "$1" worktree remove --force "$2" >/dev/null 2>&1 || :
  rm -rf "$2"
  "$GIT_BIN" -C "$1" worktree prune >/dev/null 2>&1 || :
}

# The parent-leg RED's KIND, for legibility — the same S96 detector arms
# classify_impl_failure routes through, in the same precedence. A red caused by
# the change's NEW SYMBOLS (compile / resolution) COUNTS as proof; only an env
# failure (the runner could not start in the scratch) is not proof at all.
proof_parent_red_kind() { # runner-out files-written → kind token
  local out="$1" files="$2"
  if red_gate_env_failure "$out"; then printf 'env-failure'; return 0; fi
  if red_gate_resolution_failure "$out"; then
    if unresolved_specifier_is_created "$out" "$files"; then
      printf 'missing-new-module'
    else
      printf 'bad-import-path'
    fi
    return 0
  fi
  if red_gate_compile_failure "$out"; then printf 'compile-failure'; return 0; fi
  # S157 (live-drive fidelity nit): a parent leg that died at IMPORT/collection —
  # the file threw before registering a test — was recorded as `assertion-red`,
  # because a runner reporting "1 failed" for the FILE matches the assertion
  # signature. No assertion failed; nothing ran. Discriminate on the evidence
  # already collected: a red leg that EXECUTED ZERO tests is a collection
  # failure. Placed AFTER compile/resolution so those keep precedence (they are
  # more specific about the same zero-execution situation), and it changes only
  # the recorded KIND — the verdict is unaffected, since only `env-failure`
  # changes a verdict.
  local _ec; _ec="$(proof_executed_count "$out")"
  if [ -n "$_ec" ] && [ "${_ec##* }" = 0 ]; then
    printf 'collection-red'; return 0
  fi
  if printf '%s' "$out" | grep -Eq "$(rg_signature assertion)"; then
    printf 'assertion-red'; return 0
  fi
  printf 'runner-red'
}

# S157: WHICH COPY of a test file the PARENT leg runs — the per-file decision,
# and the PROVENANCE recorded for it.
#
# THE BUG THIS FIXES (live mission lcars-20260727-001, 2026-07-27): the parent
# leg used to copy the TIP's copy of every changed test file into the scratch
# worktree. For a test file that is NEW at the parent that is exactly right — the
# behaviour it asserts does not exist yet, so it goes red. For a test file that
# ALREADY EXISTED at the parent it runs the ticket's *fixed* file against parent
# code, which means an honest REPAIR of a test that was genuinely broken on the
# parent (but whose asserted behaviour was already correct) goes GREEN on both
# legs and is rejected. That mission burned 3 rejections / 8 worker sessions on a
# correct, honestly-declared fix.
#
# THE RULE: a test file that exists at the parent sha runs the PARENT'S OWN
# COMMITTED COPY (the scratch worktree is already at the parent, so the fix is
# simply: do not overwrite it). A red then means "this file was genuinely failing
# before this ticket" — real evidence, honestly obtained.
#
# WHAT THE RULE STOPS, AND WHAT IT DOES NOT — read this before trusting it.
#
# It stops exactly one cheat, and it stops it structurally: WEAKENING AN EXISTING
# *PASSING* TEST. That file's parent copy PASSES, so no red exists and the ticket
# is rejected. That is the captain-level acceptance bar and it needs no help.
#
# It does NOT, on its own, stop a worker from GUTTING a pre-existing test file
# that happened to be red on the parent for any reason. Five rounds of
# adversarial review went into a source-reading guard for that — line counts,
# then regex names, then a character-level lexer — and every round a fresh
# reviewer broke the new version at a new token (an apostrophe in a name, a name
# inside a string, a regex literal containing `/*`, a wrapped declaration,
# `describe.skip`, `it.each` tables). Worse, its FALSE-FAILS re-created the very
# loop this session exists to kill: the last one rejected an honest repair with a
# message naming a "deleted test" that had never existed. THE CAPTAIN RULED IT
# OUT. Deciding from source whether coverage was removed is an arms race against
# language parsing, and this harness is not going to win it.
#
# WHAT REMAINS IN ITS PLACE IS ONE SOURCE-BLIND CHECK AND A HUMAN. The runners
# themselves report how many tests each leg executed, and the tip may not execute
# fewer than the parent (proof_executed_count). And every test file the ticket
# touched is already DECLARED with a reason (declared_edits_guard), so Verify
# lists the repair for the human at the gate they already stop at.
#
# THE VACUITY THAT MUST NOT BE BURIED: when the parent's copy was DEAD AT IMPORT
# it executed nothing, so "the tip executed fewer" can never fire — and that is
# precisely the flagship class this whole stage exists for (a config change made
# the file throw before registering a single test). For that case there is NO
# mechanical protection against a gutted repair at all: the declared edit and the
# human at Verify are the whole of it. The captain approved this trade with that
# fact on the table.
#
# EXISTENCE IS DECIDED FROM GIT AT THE PARENT SHA (`git cat-file -e <sha>:<rel>`),
# never from the filesystem: the scratch worktree is provisioned (node_modules,
# build output) and the tip worktree is the ticket's, so neither is authority on
# what the parent commit actually contained.
#
# A DIFF WITH ANY NON-TEST PATH TAKES THE NORMAL GATE. A repair is
# TEST-INFRASTRUCTURE ONLY. If the ticket's diff touches ANY non-test path, every
# file is staged as before — otherwise a ticket could ship behaviour under cover
# of "I was only fixing the test". Note the rule is NON-TEST, not "product
# source": a `vite.config.ts` is neither product source nor a test, and a config
# exactly like it caused the 2026-07-27 break, so it must count. The cost is that
# an honest repair carrying a README line also loses the path — which is why the
# refusal NAMES the offending paths (proof_repair_unavailable) instead of leaving
# the worker with a rejection that reads as "your broken test passes on the
# parent". `has_src` is that switch, and it is whole-ticket on purpose.
#
# THE RESIDUALS, each pinned as a KNOWN-LIMIT assertion in
# tests/proof-gates.test.sh so a comfortable silence cannot set in:
#   * A PARENT COPY DEAD AT IMPORT executes nothing, so the runner-count check is
#     VACUOUS for the flagship ground-truth class (proof-gates U6).
#   * A RUNNER WHOSE OUTPUT CARRIES NO EXECUTED COUNT (go's default, cargo), or
#     two legs parsed by different runner grammars, makes that check UNAVAILABLE
#     — recorded as `executed.checked:false`, never assumed (proof-gates U7).
#   * A TEST THAT KEEPS ITS NAME AND ITS PLACE IN THE RUN while checking less
#     (assertions orphaned in an uncalled helper, a case table emptied) changes
#     no count and is not caught (proof-gates U14).
#   * A REPAIR-ONLY TICKET satisfies this gate with no feature work of its own;
#     whether a ticket did its JOB is the acceptance criteria, Verify and the
#     full-suite gate, never this gate (proof-gates U15).
#   * A WHOLE TEST FILE RENAMED is new-at-the-parent, so the ticket is STAGED and
#     never reaches the repair path at all (proof-gates U16).
proof_parent_sources() { # parent-sha worktree rels has_src(0|1) → "<source>\t<rel>" lines
  local parent="$1" wt="$2" rels="$3" has_src="$4" rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ "$has_src" = 1 ]; then printf 'staged\t%s\n' "$rel"; continue; fi
    if "$GIT_BIN" -C "$wt" cat-file -e "$parent:$rel" 2>/dev/null; then
      printf 'parent-own\t%s\n' "$rel"
    else
      printf 'staged\t%s\n' "$rel"
    fi
  done <<PS_EOF
$rels
PS_EOF
}

# The whole-leg mode from the per-file sources: staged | parent-own | mixed
# (mixed = some of each, i.e. a test-only diff that both repairs an existing file
# and adds a new one). "none" when there are no test files at all.
proof_parent_leg_mode() { # sources → mode token
  local s="$1" nstaged nown
  nstaged="$(printf '%s\n' "$s" | grep -c '^staged	' || true)"
  nown="$(printf '%s\n' "$s" | grep -c '^parent-own	' || true)"
  if   [ "$nstaged" -gt 0 ] && [ "$nown" -gt 0 ]; then printf 'mixed'
  elif [ "$nown"    -gt 0 ];                     then printf 'parent-own'
  elif [ "$nstaged" -gt 0 ];                     then printf 'staged'
  else                                                printf 'none'
  fi
}

# === S157: THE ONE ANTI-GUTTING CHECK — WHAT THE RUNNERS ACTUALLY EXECUTED ====
# This reads NO SOURCE. Both legs already run, so it asks each runner how many
# tests it executed and refuses when the TIP executed FEWER than the PARENT did.
# It is the only anti-gutting check that survives: the source-reading guard it
# replaces was broken at a new token by five successive reviewers and was
# false-failing honest repairs, and the captain ruled it out.
#
# It catches a block that is never reached — hidden behind an `if (false)`, an
# early `return`, a `describe.skip` — where every test is still written down and
# no amount of source reading distinguishes the tip from the parent.
#
# IT COUNTS TESTS THAT RAN, not tests that were collected: vitest, jest and
# VSTest all report skipped tests inside their totals, so every arm sums
# passed+failed (or subtracts pending/skips). The two legs are compared ONLY when
# the same runner arm parsed both — two grammars mean two different notions of
# "a test", and comparing them would invent a shortfall out of nothing.
#
# THE VACUITY, stated plainly because the captain approved the trade with it on
# the table: WHEN THE PARENT'S COPY IS DEAD AT IMPORT IT EXECUTES NOTHING, so
# `tip < parent` can never fire — and that is exactly the flagship ground-truth
# class this stage exists for (a config change made the file throw before
# registering a single test). For that case this check proves nothing, and the
# declared edit plus the human at Verify are the whole of the protection.
#
# It cannot false-fail an honest repair: dropping a dead import, merging two
# assertions and re-wrapping a declaration all leave the executed count equal.
#
# STACKS IT CAN READ: node:test, vitest, jest, pytest, rspec/minitest, and the
# .NET VSTest summary. go's default output carries no count (it prints `ok pkg`),
# and cargo's is not parsed here — for those the check reports UNKNOWN and is
# SKIPPED, which is recorded in flip-flop.json rather than silently assumed.
# VERIFICATION HONESTY: only the node arm is exercised against a LIVE runner
# (proof-gates U5); the other six are pinned against their DOCUMENTED summary
# lines through the pure reader (proof-gates U13), because those runners are not
# installed in the environment this was built in.
proof_executed_count() { # runner-output → "<runner> <executed>", or empty when unreadable
  printf '%s' "$1" | "${LCARS_PYTHON_BIN:-python3}" -c '
import re, sys
out = sys.stdin.read()

# EXECUTED, not COLLECTED. E2: the first cut read each runner\x27s TOTAL, and on
# vitest, jest and VSTest that total INCLUDES skipped tests — so a whole block
# disabled with `describe.skip` reported the same number on both legs and the
# check never fired, on the very stack (vitest) that motivated this session.
# Every arm below sums the tests that actually RAN.
#
# The RUNNER TOKEN is returned with the number (F6): the two legs are only
# compared when the SAME arm parsed both, so a parent read by one runner\x27s
# grammar can never be compared against a tip read by another\x27s.

# node:test — `pass N` / `fail N` summary lines
p = re.search(r"^[^\n]*?\bpass (\d+)\s*$", out, re.M)
f = re.search(r"^[^\n]*?\bfail (\d+)\s*$", out, re.M)
if p and f:
    print("node %d" % (int(p.group(1)) + int(f.group(1)))); sys.exit(0)

# vitest — ` Tests  1 failed | 2 passed (3)` / ` Tests  3 skipped (3)`, and
# ` Tests  no tests` for a file that died at IMPORT (nothing was registered, so
# there is no `(N)` at all). That last form is what the live 2026-07-28 drive
# produced; reading it as UNKNOWN left an import-death indistinguishable from a
# real assertion failure. It is zero, and saying so is what lets the kind be
# recorded honestly.
m = re.search(r"^\s*Tests\s+(.*)$", out, re.M)
if m and re.search(r"\bno tests\b", m.group(1)):
    print("vitest 0"); sys.exit(0)
if m and re.search(r"\(\d+\)\s*$", m.group(1)):
    seg = m.group(1)
    ran = sum(int(v) for v, k in re.findall(r"(\d+) (passed|failed)", seg))
    print("vitest %d" % ran); sys.exit(0)

# jest — `Tests:  1 failed, 2 passed, 3 total` / `Tests: 3 skipped, 3 total`
m = re.search(r"^\s*Tests:\s+(.*?\d+ total)", out, re.M)
if m:
    ran = sum(int(v) for v, k in re.findall(r"(\d+) (passed|failed)", m.group(1)))
    print("jest %d" % ran); sys.exit(0)

# pytest — `3 passed, 1 failed in 0.05s`. `error` is deliberately NOT summed: a
# single test can be reported as both failed and error, and inflating the PARENT
# is the direction that invents a false shortfall.
if re.search(r"=+ .*(passed|failed|error)", out):
    ran = sum(int(v) for v in re.findall(r"(\d+) (?:passed|failed)\b", out))
    print("pytest %d" % ran); sys.exit(0)

# rspec — `3 examples, 0 failures, 3 pending`: examples counts pending too.
m = re.search(r"(\d+) examples?, (\d+) failures?(?:, (\d+) pending)?", out)
if m:
    print("rspec %d" % (int(m.group(1)) - int(m.group(3) or 0))); sys.exit(0)

# minitest — `3 runs, 0 assertions, 0 failures, 0 errors, 3 skips`
m = re.search(r"(\d+) runs?, \d+ assertions?(?:.*?(\d+) skips?)?", out)
if m:
    print("minitest %d" % (int(m.group(1)) - int(m.group(2) or 0))); sys.exit(0)

# dotnet VSTest — `Failed: 1, Passed: 2, Skipped: 0, Total: 3`
mf = re.search(r"\bFailed:\s*(\d+)", out)
mp = re.search(r"\bPassed:\s*(\d+)", out)
if mf and mp:
    print("vstest %d" % (int(mf.group(1)) + int(mp.group(1)))); sys.exit(0)
' 2>/dev/null
}

# S157 (trimmed): the REPAIR PATH IS WITHDRAWN when the ticket's diff touches any
# NON-TEST path. That routing is spec, not a heuristic — a repair is
# test-infrastructure only, and a `vite.config.ts` (neither product source nor a
# test) is exactly what broke the live mission, so "non-test" is deliberately
# broader than "product source". The cost is that an honest repair carrying a
# README line also loses the path, which is why the refusal NAMES the offending
# paths instead of leaving the worker with a rejection that reads as "your
# broken test passes on the parent".
proof_repair_unavailable() { # changed_src → reason on stdout, rc 1 when withdrawn
  local nonsrc; nonsrc="$(printf '%s' "$1" | grep . | tr '\n' ' ')"; nonsrc="${nonsrc% }"
  [ -n "$nonsrc" ] || return 0
  printf 'NOTE — the REPAIR path was not available for this ticket: its diff also changes non-test path(s) (%s), so every test file was staged into the parent as usual, including the pre-existing one(s) you edited. A repair is certified only for a diff that touches test files ALONE. If you are genuinely repairing a broken test, land that on its own ticket; if you are changing behaviour, your tests must go red on the parent on their own merits.' "$nonsrc"
  return 1
}

# flip-flop.json writer + the single finish point (event + verdict rc).
FF_TIP_RC=null; FF_TIP_TAIL=""; FF_TIP_CMD=""
FF_PAR_RC=null; FF_PAR_KIND=""; FF_PAR_TAIL=""; FF_PAR_CMD=""
# S157 provenance: which copy of each test file the parent leg uses, the whole-leg
# mode, and whether the leg actually executed. ALWAYS written to flip-flop.json —
# a reader must never have to INFER which copy was run from the verdict wording.
FF_PAR_SOURCES=""; FF_PAR_MODE="none"; FF_PAR_RAN=false
# S157 P4: why the REPAIR path was withdrawn, when a pre-existing test file was
# edited but the ticket was routed to the staged path anyway. Empty when the
# repair path was available, or when no repair was ever in question.
FF_PAR_REFUSED=""
# S157 C2: what each leg's RUNNER reported it executed. "" = the runner's output
# carried no count this reader understands, in which case the check is SKIPPED
# and recorded as such — never assumed to have passed.
FF_TIP_EXEC=""; FF_PAR_EXEC=""
_ff_reset() {
  FF_TIP_RC=null; FF_TIP_TAIL=""; FF_TIP_CMD=""
  FF_PAR_RC=null; FF_PAR_KIND=""; FF_PAR_TAIL=""; FF_PAR_CMD=""
  FF_PAR_SOURCES=""; FF_PAR_MODE="none"; FF_PAR_RAN=false
  FF_PAR_REFUSED=""
  FF_TIP_EXEC=""; FF_PAR_EXEC=""
}
# The rels carrying a given source, space-separated (for the verdict wording).
_ff_rels_with_source() { # source-token
  printf '%s\n' "$FF_PAR_SOURCES" \
    | awk -F'\t' -v k="$1" '$1==k { printf "%s%s", sep, $2; sep=" " } END { print "" }'
}
_ff_write_json() { # file ticket parent verdict reason rels
  local f="$1" t="$2" p="$3" v="$4" r="$5" rels="$6" files="" sep="" rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    files="$files$sep\"$(json_escape "$rel")\""; sep=", "
  done <<FFJ_EOF
$rels
FFJ_EOF
  local srcs="" ssep="" ssrc srel
  while IFS=$'\t' read -r ssrc srel; do
    [ -n "$srel" ] || continue
    srcs="$srcs$ssep{ \"path\": \"$(json_escape "$srel")\", \"source\": \"$(json_escape "$ssrc")\" }"
    ssep=", "
  done <<FFS_EOF
$FF_PAR_SOURCES
FFS_EOF
  {
    echo '{'
    printf '  "ticketId": "%s",\n'  "$(json_escape "$t")"
    printf '  "parentSha": "%s",\n' "$(json_escape "$p")"
    printf '  "verdict": "%s",\n'   "$(json_escape "$v")"
    printf '  "reason": "%s",\n'    "$(json_escape "$r")"
    printf '  "testFiles": [%s],\n' "$files"
    # S157 PROVENANCE, ADDITIVE and ALWAYS printed. `source` per file is which
    # copy the parent leg uses: "parent-own" (the file existed at parentSha, so
    # the parent's OWN committed copy ran — a red proves the file was already
    # broken there) or "staged" (the file is NEW at the parent, OR the ticket also
    # changed product source, so the tip's copy was copied in — today's behaviour).
    # `ran` says whether the parent leg actually executed; when it is false these
    # are the sources it WOULD have used (the gate finished earlier). Recorded so
    # no reader ever has to infer the parent leg's source from the verdict wording.
    # `repairPathRefused` (S157 P4) is the reason the repair path was WITHDRAWN
    # for a ticket that did edit a pre-existing test file — non-test paths in the
    # diff. Empty string when the repair
    # path was available, or when no repair was ever in question.
    printf '  "parentLeg": { "ran": %s, "mode": "%s", "repairPathRefused": "%s", "sources": [%s] },\n' \
      "$FF_PAR_RAN" "$(json_escape "$FF_PAR_MODE")" "$(json_escape "$FF_PAR_REFUSED")" "$srcs"
    # S157 C2 provenance: the executed-test counts the two runners reported, and
    # whether the comparison could be made at all. "" means the runner printed no
    # count this reader understands — recorded, so a skipped check is visible
    # rather than mistaken for a passed one.
    printf '  "executed": { "parent": "%s", "tip": "%s", "runner": "%s", "checked": %s },\n' \
      "$(json_escape "${FF_PAR_EXEC##* }")" "$(json_escape "${FF_TIP_EXEC##* }")" \
      "$(json_escape "${FF_TIP_EXEC%% *}")" \
      "$( [ -n "$FF_PAR_EXEC" ] && [ -n "$FF_TIP_EXEC" ] \
          && [ "${FF_PAR_EXEC%% *}" = "${FF_TIP_EXEC%% *}" ] && printf true || printf false )"
    # `cmd` is ADDITIVE (S147 DEFECT-2) — every pre-existing field keeps its name,
    # position and meaning, so the CLI verify readout and the board's
    # local_adapter._ticket_proof (both read only verdict/reason/kind) are
    # untouched. json_escape handles the quotes and `$` the command carries.
    printf '  "tip": { "rc": %s, "cmd": "%s", "tail": "%s" },\n' \
      "${FF_TIP_RC:-null}" "$(json_escape "${FF_TIP_CMD:-}")" "$(json_escape "${FF_TIP_TAIL:-}")"
    printf '  "parent": { "rc": %s, "kind": "%s", "cmd": "%s", "tail": "%s" }\n' \
      "${FF_PAR_RC:-null}" "$(json_escape "${FF_PAR_KIND:-}")" "$(json_escape "${FF_PAR_CMD:-}")" "$(json_escape "${FF_PAR_TAIL:-}")"
    echo '}'
  } >"$f"
}
_ff_finish() { # ticket parent json-file verdict reason rels → rc by verdict
  local t="$1" p="$2" f="$3" v="$4" r="$5" rels="$6"
  _ff_write_json "$f" "$t" "$p" "$v" "$r" "$rels"
  case "$v" in
    pass)
      emit_event flip_flop_pass implement \
        "flip-flop PASS for $t — tests GREEN on tip, RED on parent${FF_PAR_KIND:+ ($FF_PAR_KIND)}" "ticket=$t"
      printf '  ✓ flip-flop PASS — %s\n' "$r"
      return 0 ;;
    fail)
      emit_event flip_flop_fail implement "flip-flop FAIL for $t — $r" "ticket=$t"
      printf '  ✗ flip-flop FAIL — %s\n' "$r" >&2
      return 1 ;;
    inconclusive)
      emit_event flip_flop_inconclusive implement \
        "flip-flop INCONCLUSIVE for $t — $r (inconclusive is never a pass)" "ticket=$t"
      printf '  ✗ flip-flop INCONCLUSIVE — %s\n' "$r" >&2
      return 2 ;;
    skipped)
      emit_event flip_flop_skipped implement "flip-flop gate skipped for $t — $r" "ticket=$t"
      printf '  – flip-flop skipped — %s\n' "$r"
      return 0 ;;
  esac
}

# THE FLIP-FLOP GATE. rc 0 = pass (or declared-not-applicable skip), 1 = fail,
# 2 = inconclusive (never a pass). Writes tickets/<id>/flip-flop.json always.
flip_flop_gate() { # ticket parent-sha worktree
  local t="$1" parent="$2" wt="$3"
  local td; td="$(ticket_dir "$t")"; mkdir -p "$td"
  local ffj="$td/flip-flop.json" resf="$td/result.json"
  _ff_reset

  # Declared not-applicable → SKIP with the reason as the recorded fact
  # (declared-edits + the full suite still apply — behavior owned by S133).
  local ffdecl=""
  [ -f "$resf" ] && ffdecl="$(json_str "$resf" flipFlop)"
  if [ "$ffdecl" = "not-applicable" ]; then
    local why; why="$(json_str "$resf" flipFlopReason)"
    _ff_finish "$t" "$parent" "$ffj" skipped \
      "declared not-applicable: ${why:-no reason recorded}" ""
    return $?
  fi

  local rels; rels="$(proof_test_rels_in_diff "$parent" "$wt" existing)"
  if [ -z "$(printf '%s' "$rels" | grep . || true)" ]; then
    _ff_finish "$t" "$parent" "$ffj" inconclusive \
      "no new/changed test file in the diff vs $parent — there is nothing to flip, so fail-first cannot be proven" ""
    return $?
  fi

  # Non-test paths the change wrote — feeds the greenfield discrimination
  # (missing-new-module vs bad-import-path) exactly as classify_impl_failure does,
  # and decides repair eligibility below.
  #
  # The provisioning filter is applied HERE and ONLY here, because this is where
  # eligibility is decided. proof_diff_paths, the declared-edits guard and the
  # quality floor are deliberately left seeing the raw diff: a worker that
  # genuinely commits a dependency tree is a different problem, and it must not
  # become invisible to the guards whose job is to notice it.
  local changed_src="" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    proof_is_test_path "$p" && continue
    proof_is_provisioning_artifact "$p" "$wt" && continue
    changed_src="$changed_src$p
"
  done < <(proof_diff_paths "$parent" "$wt")

  # S157: decide the parent leg's PER-FILE SOURCE now — it is a pure git question
  # (did this path exist at $parent?) plus the whole-ticket mixed-diff switch, so
  # it is known on every exit path, including the ones that never reach the parent
  # leg. See proof_parent_sources for the rule and why the cheat still dies.
  # The candidate sources are computed with has_src=0 FIRST, so the harness knows
  # whether a repair was even in question before deciding to withdraw the path —
  # that is what lets the refusal NAME the paths that disabled it.
  FF_PAR_SOURCES="$(proof_parent_sources "$parent" "$wt" "$rels" 0)"
  FF_PAR_MODE="$(proof_parent_leg_mode "$FF_PAR_SOURCES")"
  FF_PAR_REFUSED=""
  case "$FF_PAR_MODE" in
    parent-own|mixed)
      # A diff with any NON-TEST path withdraws the repair path and falls back to
      # STAGING everything — exactly pre-S157 mechanics — carrying the reason into
      # the verdict instead of leaving a worker to guess why its genuinely-broken
      # test was judged against its own fixed copy.
      if FF_PAR_REFUSED="$(proof_repair_unavailable "$changed_src")"; then
        FF_PAR_REFUSED=""
      else
        FF_PAR_SOURCES="$(proof_parent_sources "$parent" "$wt" "$rels" 1)"
        FF_PAR_MODE="$(proof_parent_leg_mode "$FF_PAR_SOURCES")"
      fi ;;
  esac

  # --- TIP leg: the implemented tree must be GREEN on the ticket's tests -----
  proof_scoped_leg_run "$wt" "$rels"
  FF_TIP_RC="$PROOF_LEG_RC"
  FF_TIP_CMD="$PROOF_LEG_CMD"
  FF_TIP_TAIL="$(printf '%s' "$PROOF_LEG_OUT" | tail -20)"
  FF_TIP_EXEC="$(proof_executed_count "$PROOF_LEG_OUT")"
  if [ "$PROOF_LEG_RC" = 96 ] || [ "$PROOF_LEG_RC" = 97 ] || [ "$PROOF_LEG_RC" = 98 ]; then
    local tipreason="$PROOF_LEG_OUT"
    [ "$PROOF_LEG_RC" = 98 ] && tipreason="the TIP leg's $PROOF_LEG_OUT"
    _ff_finish "$t" "$parent" "$ffj" inconclusive "$tipreason" "$rels"; return $?
  fi
  if proof_zero_collected "$PROOF_LEG_OUT"; then
    _ff_finish "$t" "$parent" "$ffj" inconclusive \
      "the TIP leg collected ZERO tests — a run that selects nothing proves nothing (the green-on-nothing trap)" "$rels"
    return $?
  fi
  # GUARD 2 (S147 round 3): did everything the staged file PROMISED actually
  # run? The dotnet filter is built from a source scan, and every silent green
  # this gate has ever produced on dotnet had the same shape — the scan lost a
  # declaration, so a test the ticket wrote was never selected, never executed,
  # and still recorded as proven. This check does not care WHICH term the scan
  # emitted: it compares the tests VSTest collected against the count the staged
  # file declares, and a shortfall parks the ticket. Costs no extra run.
  # The relation is an INEQUALITY on purpose — a [Theory] expands to N cases, so
  # collected is normally GREATER than declared; only LESS is a defect.
  #
  # THE REAL BOUND, stated honestly (an earlier version of this comment claimed
  # "parser-independent", which OVERCLAIMS): the floor is produced by the SAME
  # scanner that builds the filter, so the two numbers are CORRELATED. A scan bug
  # that hides a class AND its attributes together lowers the floor by exactly
  # what it removes from the run, and cancels out. Worse, a [Theory] contributes
  # 1 to the floor but N to the observed count, so that N-1 slack is spare budget
  # a cancelled-out drop can hide inside — an OBSERVED silent green, not a
  # theoretical one. That is why the shapes we already KNOW are unselectable
  # (generic, nested, unqualified) are refused outright at command-build time by
  # GUARD 1 instead of being left to this check. GUARD 2 is the backstop for
  # unknown-unknowns — a type shape nobody has thought of yet — where the same
  # slack still exists but there is nothing more specific to say.
  if [ "$(resolve_stack)" = dotnet ]; then
    local dn_declared=0 dn_collected dn_one dn_rel2
    while IFS= read -r dn_rel2; do
      [ -n "$dn_rel2" ] || continue
      case "${dn_rel2##*/}" in *.cs) : ;; *) continue ;; esac
      dn_one="$(native_dotnet_declared_tests "$wt/$dn_rel2")"
      dn_declared=$((dn_declared + dn_one))
    done <<FF_DECL
$rels
FF_DECL
    dn_collected="$(proof_dotnet_collected_count "$PROOF_LEG_OUT")"
    if [ "$dn_declared" -gt 0 ] && [ "$dn_collected" -lt "$dn_declared" ]; then
      _ff_finish "$t" "$parent" "$ffj" inconclusive \
        "the TIP leg collected $dn_collected test(s) but the ticket's C# test file(s) declare $dn_declared — something the ticket wrote was never run, so the green cannot be trusted (a test type the harness could not name for --filter, e.g. a generic or nested class, or one the runner would not discover)" "$rels"
      return $?
    fi
  fi
  if [ "$FF_TIP_RC" -ne 0 ]; then
    _ff_finish "$t" "$parent" "$ffj" fail \
      "the TIP leg is RED (exit $FF_TIP_RC) — the ticket's tests do not pass on the implemented tree" "$rels"
    return $?
  fi

  # --- PARENT leg: a scratch worktree at the parent, each test file run from
  # the source proof_parent_sources decided — the tip's copy STAGED IN for a file
  # that is new at the parent (or when the diff also touches product source), the
  # PARENT'S OWN committed copy left in place for a file that already existed.
  local scratch; scratch="$(proof_parent_scratch "$wt" "$parent" "$t")"
  if [ -z "$scratch" ]; then
    _ff_finish "$t" "$parent" "$ffj" inconclusive \
      "could not cut the parent scratch worktree at $parent — the parent leg never ran" "$rels"
    return $?
  fi
  local rel ffsrc
  while IFS=$'\t' read -r ffsrc rel; do
    [ -n "$rel" ] || continue
    # parent-own: the scratch is ALREADY at $parent, so the file is there in its
    # committed form. Copying the tip's copy over it is precisely the bug.
    [ "$ffsrc" = staged ] || continue
    mkdir -p "$scratch/$(dirname "$rel")" 2>/dev/null || :
    cp "$wt/$rel" "$scratch/$rel" 2>/dev/null || :
  done <<FF_STAGE_EOF
$FF_PAR_SOURCES
FF_STAGE_EOF
  proof_scoped_leg_run "$scratch" "$rels"
  # `ran` is the honest fact, not "we got this far": 96/97 are the sentinels for
  # "the run could not even be CONSTRUCTED" (no testCommand, no native target, a
  # scope the runner would re-glob), so no runner started on the parent.
  case "$PROOF_LEG_RC" in 96|97) : ;; *) FF_PAR_RAN=true ;; esac
  FF_PAR_RC="$PROOF_LEG_RC"
  FF_PAR_CMD="$PROOF_LEG_CMD"
  FF_PAR_TAIL="$(printf '%s' "$PROOF_LEG_OUT" | tail -20)"
  FF_PAR_EXEC="$(proof_executed_count "$PROOF_LEG_OUT")"
  local par_out="$PROOF_LEG_OUT"
  # PRUNE FIRST — on every verdict path (behavior: pruned on success AND failure).
  proof_prune_scratch "$wt" "$scratch"

  if [ "$FF_PAR_RC" = 96 ] || [ "$FF_PAR_RC" = 97 ] || [ "$FF_PAR_RC" = 98 ]; then
    local parreason="$par_out"
    # On a PARENT-leg timeout the cause clause invites the captain to re-run the
    # recorded command — but proof_prune_scratch has ALREADY removed the scratch
    # worktree that command cd's into (pruning on every verdict path is a tested
    # invariant we keep: leaking a worktree per timeout is the worse failure), so
    # say plainly that the path is gone and how to put it back.
    [ "$FF_PAR_RC" = 98 ] && parreason="the PARENT leg's $par_out
NOTE: the parent scratch worktree has been PRUNED, so the directory this leg's recorded \`cmd\` cd's into no longer exists — re-cut it first with \`git worktree add --detach <that path> $parent\`, then paste the command."
    _ff_finish "$t" "$parent" "$ffj" inconclusive "$parreason" "$rels"; return $?
  fi
  if proof_zero_collected "$par_out"; then
    _ff_finish "$t" "$parent" "$ffj" inconclusive \
      "the PARENT leg collected ZERO tests (e.g. go's 'no tests to run' or rspec's '0 examples, 0 failures' both exit 0) — red-on-parent is unproven, and inconclusive is never a pass" "$rels"
    return $?
  fi
  # THE GREEN PARENT = NO PROOF. The wording states what was ACTUALLY proven, per
  # source mode — the S157 repair path rejects for a DIFFERENT reason than the
  # staged path, and reusing the staged sentence would describe work that did not
  # happen. The `staged` sentence is byte-identical to pre-S157 on purpose: that
  # is the unchanged new-test path.
  if [ "$FF_PAR_RC" -eq 0 ]; then
    local greenreason
    case "$FF_PAR_MODE" in
      parent-own)
        greenreason="the PARENT'S OWN copy of the ticket's pre-existing test file(s) PASSES on the parent commit ($(_ff_rels_with_source parent-own)) — nothing there was broken, so there was no repair to make and no red to prove work (rewriting or weakening a test that already passed is not proof)" ;;
      mixed)
        greenreason="the PARENT leg is GREEN both ways — the parent's OWN copy of the pre-existing test file(s) passes there ($(_ff_rels_with_source parent-own): nothing was broken to repair) and the ticket's NEW test file(s) staged into the parent pass too ($(_ff_rels_with_source staged): they assert pre-existing behavior). Neither half produces the red that proves work" ;;
      *)
        greenreason="the ticket's tests PASS on the PARENT commit — red-on-parent is not proven (a test that asserts pre-existing behavior is not proof of work)" ;;
    esac
    # S157 P4: when a pre-existing test file WAS edited and the repair path was
    # withdrawn, the sentence above is true but useless on its own — it reads as
    # "your genuinely-broken test passes on the parent". Say what disabled the
    # path. The clause is APPENDED, so the legacy sentence stays byte-identical
    # as the opening (and never appears at all on the new-test path, where no
    # repair was in question and $FF_PAR_REFUSED is empty).
    [ -n "$FF_PAR_REFUSED" ] && greenreason="$greenreason

$FF_PAR_REFUSED"
    _ff_finish "$t" "$parent" "$ffj" fail "$greenreason" "$rels"
    return $?
  fi
  FF_PAR_KIND="$(proof_parent_red_kind "$par_out" "$changed_src")"
  if [ "$FF_PAR_KIND" = env-failure ]; then
    _ff_finish "$t" "$parent" "$ffj" inconclusive \
      "the PARENT leg's runner could not start in the scratch worktree (env failure, exit $FF_PAR_RC) — a dead runner is not a red" "$rels"
    return $?
  fi
  # S157: THE ONE ANTI-GUTTING CHECK. Both legs have now run, so ask the two
  # RUNNERS how many tests each executed and refuse when the tip executed fewer.
  # Source-blind on purpose. Only on the parent-own path — a new test file has no
  # parent-side count to compare with. Vacuous when the parent copy was dead at
  # import (it executed nothing); see the block comment on proof_executed_count.
  case "$FF_PAR_MODE" in
    parent-own|mixed)
      # F6: compare only when the SAME runner arm parsed both legs. Two different
      # grammars produce two different meanings of "a test", and comparing them
      # would invent a shortfall out of nothing. Fail-closed by SKIPPING (the
      # check is recorded as not made), never by assuming it passed.
      local pruntag="${FF_PAR_EXEC%% *}" truntag="${FF_TIP_EXEC%% *}"
      local parn="${FF_PAR_EXEC##* }" tipn="${FF_TIP_EXEC##* }"
      if [ -n "$FF_PAR_EXEC" ] && [ -n "$FF_TIP_EXEC" ] && [ "$pruntag" = "$truntag" ] \
         && [ "$tipn" -lt "$parn" ]; then
        _ff_finish "$t" "$parent" "$ffj" fail \
          "the ticket claims a REPAIR, but the RUNNER executed FEWER tests on the tip than on the parent ($parn → $tipn). Whatever the source says, tests that used to run no longer do — a disabled block (\`describe.skip\`, an \`if (false)\`, an early return) hides tests that are still written down. This count comes from the runners themselves, not from reading your file. Make the missing tests run again." "$rels"
        return $?
      fi ;;
  esac

  # THE RED = PROOF. Again per mode, and stating the REAL bound: the leg runs the
  # ticket's test files together, so a red proves THAT RUN was failing on the
  # parent — it is not attributed to an individual file when there is more than one.
  local passreason
  case "$FF_PAR_MODE" in
    parent-own)
      # D2: state the facts established, nothing about intent. The gate proved
      # three things and no more — parent copy red, tip copy green, file did not
      # shrink. It cannot see whether the assertions still MEAN the same thing.
      passreason="tests GREEN on tip, RED on parent (exit $FF_PAR_RC, $FF_PAR_KIND). ESTABLISHED: the parent leg ran the parent's OWN committed copy of $(_ff_rels_with_source parent-own) — never the ticket's edited one — that copy FAILED at the parent while the ticket's copy passes at the tip, and — where both legs were read by the same runner — the tip executed at least as many tests as the parent (${FF_PAR_EXEC##* } → ${FF_TIP_EXEC##* }, via ${FF_TIP_EXEC%% *}). NOT established: that a test which survived still checks anything, or that no test was REMOVED. Note especially: if the parent's copy was dead at import it executed nothing, so the count comparison proves nothing here and the declared edit plus your review at Verify are the only protection. The harness does not read the test source to decide any of this" ;;
    mixed)
      passreason="tests GREEN on tip, RED on parent (exit $FF_PAR_RC, $FF_PAR_KIND) — the parent leg ran the parent's OWN copy of the pre-existing test file(s) ($(_ff_rels_with_source parent-own)), run from the parent's own committed copy, together with the ticket's new file(s) staged in ($(_ff_rels_with_source staged)). The red is from that run as a whole; the harness did not attribute it to one file" ;;
    *)
      passreason="tests GREEN on tip, RED on parent (exit $FF_PAR_RC, $FF_PAR_KIND — a compile/resolution red from the change's new symbols counts as proof)" ;;
  esac
  _ff_finish "$t" "$parent" "$ffj" pass "$passreason" "$rels"
}

# result.json's declared test paths: newTests ∪ testEdits[].path, one per line.
proof_result_declared_paths() { # result-file
  "${LCARS_PYTHON_BIN:-python3}" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
out = []
for p in (d.get("newTests") or []):
    if isinstance(p, str) and p: out.append(p)
for e in (d.get("testEdits") or []):
    if isinstance(e, dict) and e.get("path"): out.append(e["path"])
sys.stdout.write("\n".join(out))
' "$1" 2>/dev/null
}

# Persist the declared edits as the ticket's durable {path, reason} artifact.
proof_write_test_edits() { # result-file out-file
  "${LCARS_PYTHON_BIN:-python3}" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
edits = [e for e in (d.get("testEdits") or []) if isinstance(e, dict) and e.get("path")]
with open(sys.argv[2], "w") as f:
    json.dump([{"path": e.get("path"), "reason": e.get("reason", "")} for e in edits], f, indent=2)
    f.write("\n")
' "$1" "$2" 2>/dev/null
}

# THE DECLARED-EDITS GUARD. Every test-classified path in the diff vs the parent
# must be declared (newTests ∪ testEdits[].path); deletions count as edits. Any
# remainder is an UNDECLARED edit → fail, files named. No repo-wide hashing —
# the parent commit IS the snapshot. rc 0 = clean (test-edits.json + event
# written), 1 = undeclared / no result to check against.
declared_edits_guard() { # ticket parent-sha worktree
  local t="$1" parent="$2" wt="$3"
  local td; td="$(ticket_dir "$t")"; local resf="$td/result.json"
  if [ ! -f "$resf" ]; then
    printf 'proof-gate: declared-edits guard — no result.json for %s, so declarations cannot be verified.\n' "$t" >&2
    return 1
  fi
  local rels declared undeclared="" p
  rels="$(proof_test_rels_in_diff "$parent" "$wt")"     # all — deletions included
  declared="$(proof_result_declared_paths "$resf")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$declared" | grep -Fxq "$p" || undeclared="${undeclared:+$undeclared }$p"
  done <<DE_EOF
$rels
DE_EOF
  if [ -n "$undeclared" ]; then
    printf 'proof-gate: UNDECLARED test edit(s) for %s — the diff vs %s touches test-classified file(s) the result never declared (newTests / testEdits): %s. Deletions count as edits. Declare every test edit with a reason, or leave the file untouched.\n' \
      "$t" "$parent" "$undeclared" >&2
    return 1
  fi
  proof_write_test_edits "$resf" "$td/test-edits.json"
  local n; n="$(printf '%s\n' "$declared" | grep -c . || true)"
  emit_event ticket_test_edits implement \
    "ticket $t test-edit declarations verified against the diff vs $parent ($n declared path(s)) — recorded to test-edits.json" \
    "ticket=$t"
  return 0
}

# result.json v2 validation — the unified worker's contract. NO dual-shape
# support: a v1 file REJECTS with the missing keys NAMED (the path flips in
# S133, and an old-shape result must never be silently accepted).
proof_validate_result() { # result-file [ticket] → 0 valid, 1 reject (reason on stderr)
  local f="$1" t="${2:-}"
  [ -n "$f" ] && [ -f "$f" ] || { printf 'proof-gate: no result file to validate.\n' >&2; return 1; }
  local missing="" k
  for k in ticketId passed attempts summary newTests testEdits flipFlop; do
    grep -q "\"$k\"" "$f" || missing="${missing:+$missing, }\"$k\""
  done
  if [ -n "$missing" ]; then
    printf 'proof-gate: result.json REJECTED — missing key(s): %s. This gate accepts ONLY the v2 unified-worker shape {ticketId, passed, attempts, summary, newTests[], testEdits[] ({path, reason}), flipFlop: "expected"|"not-applicable", flipFlopReason (required iff not-applicable)}; the v1 {ticketId, passed, attempts, summary} shape is not valid here.\n' "$missing" >&2
    return 1
  fi
  local rid passed attempts ffv ffr
  rid="$(json_str "$f" ticketId)"
  passed="$(json_raw "$f" passed)"
  attempts="$(json_raw "$f" attempts)"
  ffv="$(json_str "$f" flipFlop)"
  ffr="$(json_str "$f" flipFlopReason)"
  if [ -n "$t" ] && [ "$rid" != "$t" ]; then
    printf 'proof-gate: result.json REJECTED — ticketId "%s" does not match the ticket "%s".\n' "$rid" "$t" >&2
    return 1
  fi
  case "$passed" in true|false) : ;; *)
    printf 'proof-gate: result.json REJECTED — "passed" must be true or false.\n' >&2; return 1 ;; esac
  case "$attempts" in ''|*[!0-9]*)
    printf 'proof-gate: result.json REJECTED — "attempts" must be a number.\n' >&2; return 1 ;; esac
  # S133: attempts is the worker's OWN iteration count — informational,
  # uncapped-but-reported (the enforced cap is the session bounce loop).
  if [ "$attempts" -lt 1 ]; then
    printf 'proof-gate: result.json REJECTED — "attempts" is %s; it must be at least 1.\n' "$attempts" >&2
    return 1
  fi
  case "$ffv" in
    expected) : ;;
    not-applicable)
      if [ -z "$ffr" ]; then
        printf 'proof-gate: result.json REJECTED — flipFlop is "not-applicable" but "flipFlopReason" is missing/empty. The reason IS the recorded fact; it is required.\n' >&2
        return 1
      fi ;;
    *)
      printf 'proof-gate: result.json REJECTED — "flipFlop" must be "expected" or "not-applicable" (got "%s").\n' "$ffv" >&2
      return 1 ;;
  esac
  local structerr
  structerr="$("${LCARS_PYTHON_BIN:-python3}" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("proof-gate: result.json REJECTED — not valid JSON: %s" % e); sys.exit(1)
nt = d.get("newTests"); te = d.get("testEdits")
if not isinstance(nt, list) or any(not (isinstance(p, str) and p) for p in nt):
    print("proof-gate: result.json REJECTED — \"newTests\" must be an array of non-empty path strings."); sys.exit(1)
if d.get("flipFlop") == "not-applicable" and nt:
    print("proof-gate: result.json REJECTED — the result declares new tests yet claims flip-flop \"not-applicable\"; a ticket that authors tests must expect them to flip. Declare flipFlop \"expected\", or drop the tests."); sys.exit(1)
def bad(e):
    return not (isinstance(e, dict) and isinstance(e.get("path"), str) and e["path"]
                and isinstance(e.get("reason"), str) and e["reason"])
if not isinstance(te, list) or any(bad(e) for e in te):
    print("proof-gate: result.json REJECTED — \"testEdits\" must be an array of {path, reason} objects (both non-empty strings)."); sys.exit(1)
' "$f" 2>&1)" || { printf '%s\n' "$structerr" >&2; return 1; }
  return 0
}

# THE QUALITY FLOOR. ≥1 new/changed test in the diff AND suite_has_assertions
# over those files (judged in-tree at the tip), unless the result declares
# flipFlop=not-applicable — then the declared reason is the recorded fact and
# the floor is waived (declared-edits + the full suite still apply).
proof_quality_floor() { # ticket parent-sha worktree → 0 ok/waived, 1 fail
  local t="$1" parent="$2" wt="$3"
  local resf; resf="$(ticket_dir "$t")/result.json"
  local ffv=""; [ -f "$resf" ] && ffv="$(json_str "$resf" flipFlop)"
  if [ "$ffv" = "not-applicable" ]; then
    return 0
  fi
  local rels; rels="$(proof_test_rels_in_diff "$parent" "$wt" existing)"
  if [ -z "$(printf '%s' "$rels" | grep . || true)" ]; then
    printf 'proof-gate: QUALITY FLOOR — ticket %s has NO new/changed test file in its diff vs %s; at least one is required unless the result declares flipFlop "not-applicable" (with a reason).\n' \
      "$t" "$parent" >&2
    return 1
  fi
  local qd rel; qd="$(mktemp -d)"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$qd/$(dirname "$rel")" 2>/dev/null || :
    cp "$wt/$rel" "$qd/$rel" 2>/dev/null || :
  done <<QF_EOF
$rels
QF_EOF
  if suite_has_assertions "$qd"; then
    rm -rf "$qd"
    return 0
  fi
  rm -rf "$qd"
  printf 'proof-gate: QUALITY FLOOR — ticket %s new/changed test file(s) contain NO recognizable assertion; a test that claims nothing proves nothing.\n' "$t" >&2
  return 1
}

# --- S133: the standoff persistence subcommands are RETIRED -----------------
# cmd_impl_save_tests (js/py placement + red gate), its native (rust/go)
# counterpart, and native-scope are deleted with the Test-Writer/Implementer
# standoff: the unified TDD worker authors its tests IN-TREE at the repo's own
# convention, and proof moves AFTER implementation (the S132 gates driven by
# cmd_implement_ticket). The parent commit is the snapshot.

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
# S111 (the 002 wrong-tree lesson): when a post-commit red says "implementation
# not present on the committed branch", the code often EXISTS — sitting as
# uncommitted edits in the WRONG tree (the shared clone root) because a worker
# wandered out of its isolated worktree. Name that instead of leaving a mystery.
# Pure + read-only: resolves the MAIN checkout from the git common dir, and only
# reports when the gate ran ISOLATED from it (in a non-isolated run the main
# tree's edits ARE the build). Echoes a bounded note, or nothing.
stray_edit_note() { # → wrong-tree note (empty when clean / non-isolated / unknown)
  local common main status here
  common="$( cd "${REPO_ROOT:-.}" 2>/dev/null && "$GIT_BIN" rev-parse --git-common-dir 2>/dev/null )"
  [ -n "$common" ] || return 0
  case "$common" in /*) : ;; *) common="${REPO_ROOT:-.}/$common" ;; esac
  main="$(dirname "$common")"
  [ -d "$main" ] || return 0
  here="$( cd "${REPO_ROOT:-.}" 2>/dev/null && pwd -P )"
  [ "$( cd "$main" && pwd -P )" != "$here" ] || return 0
  status="$( cd "$main" && "$GIT_BIN" status --porcelain 2>/dev/null | head -10 )"
  [ -n "$status" ] || return 0
  # Fire only when a TRACKED file is modified — untracked-only noise (the
  # captain's own scratch files in the clone root) is not a wrong-tree signal,
  # but a worker that wandered always dirties the tracked sources it edited.
  printf '%s\n' "$status" | grep -q '^[^?]' || return 0
  local br; br="$( cd "$main" && "$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null )"
  printf ' NOTE — WRONG-TREE SUSPECT: the MAIN checkout at %s (on %s) carries uncommitted edits:\n%s\nA worker may have written its implementation into the SHARED clone root instead of this ticket'\''s isolated worktree — inspect those paths before re-running (the code may exist, just in the wrong tree).' \
    "$main" "${br:-?}" "$status"
}

# stale_dep_env_reason — evidence that a gate worktree's installed dependencies
# are NOT the ones its own committed lockfile asks for. Echoes a human reason, or
# nothing when there is no such evidence.
#
# The companion to red_gate_env_failure, which keys on the runner failing to
# START (command-not-found class). This is the case where the runner starts
# perfectly and still cannot be believed: worktreeSetupCommand provisions a gate
# worktree by SYMLINKING the main checkout's node_modules, which is correct right
# up until a ticket CHANGES dependencies. Then the shared install is the wrong
# set by definition, the ticket's committed lockfile fix cannot take effect, and
# the red that follows gets reported as "the implementation is NOT present on the
# committed branch" — an accusation about code, for an environment fault. No
# committed change can ever clear it, so the ticket burns its whole retry budget.
#
# CONSERVATIVE: reports only on POSITIVE evidence — deps shared by symlink from
# ANOTHER checkout, AND a lockfile that differs from that checkout's. A worktree
# that owns its node_modules is by definition testing its own dependencies, and
# an ABSENT node_modules is red_gate_env_failure's business. With no evidence it
# stays silent, so a genuinely missing implementation keeps its correct wording.
stale_dep_env_reason() { # worktree → reason (empty ⇒ no evidence of staleness)
  local wt="${1:-}" lock target main
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  # Only decidable when the deps are SHARED in from somewhere else.
  [ -L "$wt/node_modules" ] || return 0
  target="$( cd "$wt" 2>/dev/null && readlink node_modules 2>/dev/null )" || return 0
  [ -n "$target" ] || return 0
  case "$target" in /*) : ;; *) target="$wt/$target" ;; esac
  main="${target%/node_modules}"
  [ -d "$main" ] || return 0
  [ "$main" = "$wt" ] && return 0
  for lock in package-lock.json pnpm-lock.yaml yarn.lock; do
    if [ -f "$wt/$lock" ] && [ -f "$main/$lock" ] \
       && ! cmp -s "$wt/$lock" "$main/$lock"; then
      printf 'this worktree'\''s %s differs from the shared install it was given (symlinked from %s), so the suite ran against the WRONG dependency set' \
        "$lock" "$main"
      return 0
    fi
  done
  return 0
}

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

  # S133 (unified worker): the ticket's tests were authored IN-TREE and committed
  # WITH the source in the ONE ticket commit, so they are already present in this
  # clean worktree — run them IN PLACE, scoped to the proof-time recorded relpaths.
  # CROSS-BOUNDARY DRIFT (declared-edits-aware, replaces the tests.sha256 re-hash):
  # a committed test whose blob no longer matches its proof-time hash is fine IFF
  # some ticket DECLARED that edit (test-edits.json); an UNDECLARED drift is the
  # tampering violation, returned as the DISTINCT code (4) exactly as before.
  # S87: a sub-package ticket runs vitest/jest FROM its package root (run_dir=<wt>/<pkg>)
  # for discovery/config; an empty pkg_rel runs from the worktree root.
  local pkg_rel; pkg_rel="$(ticket_target_package "$t" "$wt")"
  local run_dir rc=0 out="" rels scope tamper=0 undecl
  run_dir="$wt"
  if [ -n "$pkg_rel" ]; then run_dir="$wt/$pkg_rel"
  else
    # S133: package-spanning ticket → run from the package its tests live in.
    local _pcpkg; _pcpkg="$(ticket_tests_package "$t" "$wt")"
    [ -n "$_pcpkg" ] && run_dir="$wt/$_pcpkg"
  fi
  rels="$(proof_snapshot_rels "$t")"
  if [ -n "$(printf '%s' "$rels" | grep . || true)" ]; then
    undecl="$(proof_drift_declared_ok "$t" "$wt")" || {
      tamper=1
      local tdetail="POST-COMMIT GATE — UNDECLARED TEST DRIFT: ticket $t's COMMITTED test file(s) no longer match the proof-time snapshot (proof-tests.sha256) and NO ticket declared that edit (test-edits.json): $(printf '%s' "$undecl" | tr '\n' ' '). A test may only change when the editing ticket declares it with a reason; refusing. This is NOT a normal red and is NOT self-healable. Restore the test or re-open the ticket."
      printf '  ✗ %s\n' "$tdetail" >&2
      [ -n "$POST_COMMIT_SIGNAL" ] && printf '%s\n' "$tdetail" >"$POST_COMMIT_SIGNAL"
    }
    if [ "$tamper" != 1 ]; then
      # Run only the still-present recorded tests (a DECLARED deletion is legal).
      local _pcrels="" _pcr
      while IFS= read -r _pcr; do
        [ -n "$_pcr" ] && [ -f "$wt/$_pcr" ] && _pcrels="${_pcrels}${_pcr}
"
      done <<PC_RELS_EOF
$rels
PC_RELS_EOF
      if [ -n "$(printf '%s' "$_pcrels" | grep . || true)" ]; then
        scope="$(intree_scope_for "$wt" "$_pcrels")"
        out="$( cd "$run_dir" && LCARS_TESTS_DIR="$scope" bash -c "$cmd" 2>&1 )" || rc=$?
      fi
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

  # STALE-ENV (companion to the startup check above): the runner STARTED, so the
  # env is "provisioned" — but it was handed a shared install that does not match
  # this worktree's own committed lockfile. The code may be perfectly present;
  # it was simply tested against the dependencies its own commit replaced. Blaming
  # the implementation here is not just unhelpful, it is unfixable: no committed
  # change can alter what the gate symlinks in, so the ticket bounces to a fresh
  # worker until its retry budget is gone. Same DISTINCT code (3) as the startup
  # failure, so the call site already routes it as an environment fault.
  local stale; stale="$(stale_dep_env_reason "$wt")"
  if [ -n "$stale" ]; then
    local sdetail="POST-COMMIT GATE — STALE DEPENDENCY ENVIRONMENT — ticket $t's suite is RED, but $stale. This is NOT a missing implementation and NO committed change can fix it: the gate reuses the main checkout's installed deps, so a ticket that changes dependencies must have them installed. Repair the provisioning with \`lcars update\` (its worktreeSetupCommand migration reinstalls on a lockfile divergence). Command run: $cmd."
    printf '  ✗ %s\n' "$sdetail" >&2
    [ -n "$POST_COMMIT_SIGNAL" ] && printf '%s\n' "$sdetail" >"$POST_COMMIT_SIGNAL"
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

  # S133 (unified worker): validate the v2 result shape — ticketId match, passed,
  # honest uncapped attempts, newTests/testEdits/flipFlop. A v1 (standoff-era)
  # result REJECTS legibly; there is no dual-shape support.
  proof_validate_result "$RESULT" "$TICKET" \
    || die "result for $TICKET failed v2 validation (see the proof-gate reason above)."

  local passed attempts
  passed="$(json_raw "$RESULT" passed)"
  attempts="$(json_raw "$RESULT" attempts)"

  cp "$RESULT" "$(ticket_dir "$TICKET")/result.json"

  if [ "$passed" = "false" ]; then
    # The worker itself reports the ticket not green. Flag the human — same
    # awaiting-human gate shape as validate-pause: persist the blocker, set the
    # state fields, overlay the label, and stop. (cmd_implement_ticket normally
    # bounces a passed:false session before reaching here; this is the direct-
    # invocation recourse.)
    rm -f "$(ticket_dir "$TICKET")/result.json"   # never let a failed result read as green
    local q; q="$(mktemp)"
    printf 'Ticket %s could not be made green (the worker iterated %s time(s)): %s\n' \
      "$TICKET" "$attempts" "$(json_str "$RESULT" summary)" >"$q"
    write_pending "$q" "implement"
    state_set_raw awaitingHuman true
    state_set_str pendingQuestion "Ticket $TICKET failed — needs a human."
    gh_relabel "lcars:awaiting-human" ""
    rm -f "$q"

    emit_event ticket_flagged implement "ticket $TICKET flagged (worker reported not green after $attempts iteration(s))" \
      "ticket=$TICKET" "attempts=$attempts"

    echo "IMPLEMENT: ticket flagged — $TICKET"
    echo "  $TICKET is still not green (the worker reported $attempts iteration(s))."
    echo "  Flagged the human. Stage: implement (awaiting-human)."
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
        # S133 (declared-edits-aware drift): a COMMITTED test of this ticket no
        # longer matches its proof-time snapshot and NO ticket declared the edit
        # (test-edits.json). Route it like the old tampering violation: a distinct
        # event + a loud die. A test may only change when the editing ticket
        # declares it with a reason.
        emit_event ticket_locked_test_tampered implement \
          "ticket $TICKET — committed test no longer matches the proof-time snapshot and no ticket declared the edit (undeclared drift across the commit boundary)" \
          "ticket=$TICKET" "attempts=$attempts"
        die "ticket $TICKET — UNDECLARED TEST DRIFT: a COMMITTED test file no longer matches its proof-time snapshot and no ticket declared that edit. Green must be earned by implementing; a test edit must be declared with a reason. Rejected by the cross-boundary drift guardrail.$why"
        ;;
      *)
        # S111: before declaring the work missing, check whether it landed in the
        # WRONG tree (uncommitted edits in the shared clone root — the S110 002
        # failure) and say so in the die text.
        local stray; stray="$(stray_edit_note)"
        emit_event ticket_postcommit_red implement \
          "ticket $TICKET failed the post-commit check — implementation not present on the committed branch${stray:+ (wrong-tree suspect: uncommitted edits found in the main checkout)}" \
          "ticket=$TICKET" "attempts=$attempts"
        die "ticket $TICKET reported green but its suite is RED against the COMMITTED branch state — the implementation is not present on the committed branch (worktree-only green or out-of-scope commit). Result rejected by the post-commit guardrail.$why$stray"
        ;;
    esac
  fi
  rm -f "$pcsig"

  # The change is confirmed present and GREEN on the committed branch — record the
  # successful post-commit verification so the stream / `--watch` view show it.
  emit_event ticket_postcommit_ok implement \
    "ticket $TICKET verified green on the committed branch" \
    "ticket=$TICKET" "attempts=$attempts"

  # S111 3′: a declared test setup that carried this ticket all the way to a
  # post-commit-verified green is now a PROVEN fact — record it to the repo's
  # test landscape (durable, human-visible, one file per package).
  record_test_landscape

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
  echo "  Build these (unified TDD implementer, one worker per ticket) before wave $((cur + 1))."
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
# --- SHARED: re-run every named ticket's ridden-along suite against a given tree -
# Extracted from full_suite_gate (BUG-013) so BOTH the full-suite gate AND the
# S76 reconcile gate re-test ticket suites the SAME way. S133 (unified worker):
# each ticket's tests were authored IN-TREE and committed WITH its source, so the
# retest runs them IN PLACE at their committed paths, scoped via $LCARS_TESTS_DIR
# to the proof-time recorded relpaths (proof-tests.sha256). $run_dir is the tree
# to run against (a worktree at the branch tip for the gate, the reconcile merge
# worktree for the reconcile). On any per-ticket non-zero exit the ticket id is
# appended to the global $RETEST_FAILED list, and (when $RETEST_CAPTURE is set)
# its combined stdout/stderr is captured to $RETEST_CAPTURE/<id>.log so the
# reconcile author can quote the failure. Returns 0 iff every suite passed.
# The absolute $LCARS_TESTS_DIR scope for a set of relpaths: the single file when
# there is exactly one (precise positional filter), else the deepest COMMON ANCESTOR
# dir of the files — so a ticket whose tests span multiple dirs re-tests
# symmetrically here (post-commit / full-suite / reconcile). Empty rels → the tree.
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
RETEST_TAMPERED=""   # S133: ids whose COMMITTED test drifted UNDECLARED from the proof snapshot
RETEST_CAPTURE=""    # caller may point this at a dir to capture per-ticket output
retest_ticket_suites() { # run_dir  cmd  ordered ticketId...
  local run_dir="$1" cmd="$2"; shift 2
  RETEST_FAILED=""
  RETEST_TAMPERED=""
  local id rc out pkg_rel trun rels scope undecl
  for id in "$@"; do
    [ -n "$id" ] || continue
    rels="$(proof_snapshot_rels "$id")"
    # Defensive: a green ticket should have recorded proof tests. A ticket with
    # none (a declared flipFlop=not-applicable ticket, or a pre-S133 record) has
    # nothing of its own to re-run — skip it rather than crash; we never INVENT
    # a failure.
    [ -n "$(printf '%s' "$rels" | grep . || true)" ] || continue
    # S87: PER-TICKET, a sub-package ticket re-runs INSIDE its own package (vitest/
    # jest discover & filter at the package root); an empty pkg_rel runs from the
    # run-tree root. Checked against $run_dir so every caller (full-suite gate
    # worktree, reconcile merge worktree) stays symmetric.
    pkg_rel="$(ticket_target_package "$id" "$run_dir")"
    trun="$run_dir"
    if [ -n "$pkg_rel" ]; then trun="$run_dir/$pkg_rel"
    else
      # S133: package-spanning ticket → re-run from the package its tests live in.
      local _fspkg; _fspkg="$(ticket_tests_package "$id" "$run_dir")"
      [ -n "$_fspkg" ] && trun="$run_dir/$_fspkg"
    fi
    rc=0
    # PRE-MERGE CROSS-BOUNDARY DRIFT (S133, declared-edits-aware — replaces the
    # tests.sha256 re-hash): a committed test whose blob no longer matches its
    # proof-time hash is legal IFF the editing ticket DECLARED it (test-edits.json
    # — a LATER ticket may adapt an EARLIER ticket's test, with a reason). An
    # UNDECLARED drift is the tampering violation: BLOCK LOUD (this is not a
    # regression to self-heal; the Mission must NOT merge an undeclared edit). We
    # `die` here so EVERY caller — the full-suite gate AND the reconcile — stops
    # with the drift reason rather than proceeding to merge or self-heal.
    undecl="$(proof_drift_declared_ok "$id" "$run_dir")" || {
      RETEST_TAMPERED="${RETEST_TAMPERED:+$RETEST_TAMPERED }$id"
      emit_event ticket_locked_test_tampered implement \
        "ticket $id — committed test drifted from the proof-time snapshot with no declaring ticket (pre-merge drift check)" \
        "ticket=$id" || :
      die "PRE-MERGE UNDECLARED TEST DRIFT: ticket $id's COMMITTED test file(s) no longer match the proof-time snapshot and NO ticket declared that edit (test-edits.json): $(printf '%s' "$undecl" | tr '\n' ' '). BLOCKED: the Mission cannot merge an undeclared test edit, and this is NOT a self-healable regression. Restore the test or re-open the ticket."
    }
    # Run only the still-present recorded tests IN PLACE at their committed paths
    # (a DECLARED deletion is legal and simply has nothing to re-run).
    local _rrels="" _rr
    while IFS= read -r _rr; do
      [ -n "$_rr" ] && [ -f "$run_dir/$_rr" ] && _rrels="${_rrels}${_rr}
"
    done <<RT_RELS_EOF
$rels
RT_RELS_EOF
    [ -n "$(printf '%s' "$_rrels" | grep . || true)" ] || continue
    scope="$(intree_scope_for "$run_dir" "$_rrels")"
    out="$( cd "$trun" && LCARS_TESTS_DIR="$scope" bash -c "$cmd" 2>&1 )" || rc=$?
    if [ "$rc" -ne 0 ]; then
      RETEST_FAILED="${RETEST_FAILED:+$RETEST_FAILED }$id"
      [ -n "$RETEST_CAPTURE" ] && { mkdir -p "$RETEST_CAPTURE"; printf '%s\n' "$out" >"$RETEST_CAPTURE/$id.log"; }
    fi
  done
  [ -z "$RETEST_FAILED" ]
}

FULL_SUITE_SIGNAL=""   # caller may point this at a file to capture the regression detail
# S157: the ticket ids whose OWN recorded suites failed in the LAST full_suite_gate
# run — i.e. the tickets that AUTHORED the failing tests. Empty on a pass, and
# empty on the env-unprovisioned path (a runner that never started attributes
# nothing to anybody). Read by self_heal_full_suite / escalate_full_suite_regression
# through selfheal_regressor; never inferred from the reason prose.
FULL_SUITE_REGRESSED=""
# S157 × #93: the gate failed for an ENVIRONMENT reason — a stale dependency
# environment or an unprovisioned one — so NO ticket can be attributed the break
# and no worker edit can clear it. Distinct from "the list happens to be empty":
# a regression whose owner could not be resolved would leave the list empty too,
# and that case must still reach self-heal on its `unresolved-last-built` basis.
# This flag is the FACT; the empty list is its consequence.
FULL_SUITE_ENV_FAULT=""
full_suite_gate() { # ordered ticketId...
  FULL_SUITE_REGRESSED=""
  FULL_SUITE_ENV_FAULT=""
  local cmd; cmd="$(resolve_test_cmd)"
  FULL_SUITE_STALE_ENV=""   # reset per call — never inherit a prior gate's verdict
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
  # S111: with a real branch a failed worktree cut is LOUD (make_ticket_worktree
  # rc!=0) — retesting in the SHARED checkout instead would judge the suites
  # against whatever branch happens to be checked out there (false regressions /
  # false greens). Only the branch-less empty return may fall through to in-tree.
  wt="$(make_ticket_worktree "$wt_base" "$branch" "all")" \
    || die "the full-suite gate could not cut its verification worktree (see the error above) — refusing to retest in the shared checkout. Free or prune stale worktrees (\`git worktree list\`, \`git worktree prune\`) and re-run."
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
    # Read the dependency-environment evidence BEFORE the worktree is torn down —
    # the classification below runs after this block, when the path is gone.
    FULL_SUITE_STALE_ENV="$(stale_dep_env_reason "$wt")"
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
      FULL_SUITE_ENV_FAULT="unprovisioned"
      rm -rf "$cap" 2>/dev/null
      printf '  ✗ %s\n' "$edetail" >&2
      [ -n "$FULL_SUITE_SIGNAL" ] && printf '%s\n' "$edetail" >"$FULL_SUITE_SIGNAL"
      return 1
    fi
  fi

  # STALE-ENV (same fault, same reasoning as the post-commit gate): the runner
  # started fine but was handed a shared install that does not match this
  # worktree's committed lockfile, so "these suites regressed" names the wrong
  # culprit — the earlier tickets did not regress, they were re-run against the
  # wrong dependency set. Diagnosis only; the gate still fails.
  #
  # ORDERING IS LOAD-BEARING (S157 × #93 merge seam). This block returns BEFORE
  # FULL_SUITE_REGRESSED is set, so a stale-dependency failure attributes to NO
  # ticket and self-heal dispatches nobody. Moving the assignment above this
  # early return would hand a worker a ticket to "fix" for a break that is a
  # toolchain fault — the false-premise reconcile both changes exist to end.
  if [ -n "${FULL_SUITE_STALE_ENV:-}" ]; then
    local sdetail="FULL-SUITE GATE — STALE DEPENDENCY ENVIRONMENT — the re-run went RED, but ${FULL_SUITE_STALE_ENV}. These suites did NOT necessarily regress: they were re-run against dependencies this branch's own lockfile replaced. Repair the provisioning with \`lcars update\` (its worktreeSetupCommand migration reinstalls on a lockfile divergence), then re-run. Command run: $cmd."
    emit_event ticket_env_unprovisioned implement \
      "full-suite gate — stale dependency environment (the gate worktree's lockfile differs from the shared install it was symlinked); repair with \`lcars update\`" \
      "" || :
    FULL_SUITE_ENV_FAULT="stale-deps"
    rm -rf "$cap" 2>/dev/null
    printf '  ✗ %s\n' "$sdetail" >&2
    [ -n "$FULL_SUITE_SIGNAL" ] && printf '%s\n' "$sdetail" >"$FULL_SUITE_SIGNAL"
    return 1
  fi

  # S157: the ids are recorded for attribution BEFORE the prose is built, so the
  # consumer reads a list, not a sentence. (The reason string still carries them
  # in the same phrase — escalate_full_suite_regression's sed still matches.)
  FULL_SUITE_REGRESSED="$regressed"
  # S157 — THE PREMISE HAD TO GO. The old copy asserted "a LATER ticket's produced
  # code REGRESSED its locked contract". This gate does not prove that: it proves
  # each named ticket's OWN tests, green when that ticket was built, no longer
  # pass on the assembled branch. A same-wave sibling (blind by design), an
  # interaction between two changes each built in isolation, or a later ticket are
  # all consistent with the same evidence — and in the 2026-07-27 mission the
  # confident wrong premise sent a worker to the wrong ticket for 8 sessions.
  local detail="FULL-SUITE GATE — these ticket suite(s) no longer pass against the fully-built repo: ${regressed}. Each is named because ITS OWN recorded tests were re-run and failed, and each was green when its own ticket was built — so something that landed since has broken it. WHICH change is NOT established by this gate (a later ticket, a same-wave sibling built blind to it, or an interaction between changes are all consistent with this evidence). The Mission is NOT shippable until it is resolved. Command run: $cmd."
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
# --- S157: WHICH TICKET a full-suite regression is handed to ----------------
# The old rule was "the latest one built (last in plan order)" — a GUESS. In the
# 2026-07-27 mission it handed a reconcile brief for a break in t-012's test file
# to t-011, whose only distinction was landing last; the worker spent 8 sessions
# on a premise that was simply false.
#
# The gate already knows better: retest_ticket_suites re-runs EACH ticket's OWN
# recorded test files and records the ids whose runs failed, so a failing id IS
# the ticket that authored the failing suite. That is the ownership fact, and it
# is all we claim — authoring the broken test is NOT the same as having caused
# the break (the cause may be another ticket's code the test now runs against),
# which is why the brief says so out loud.
#
# THE TIE-BREAK, when several tickets' suites fail: take the one that comes
# FIRST IN `$ordered`. That list is built by cmd_impl_advance from waves.json, so
# it is WAVE order — which since S156 (this same branch, infrastructure tickets
# pulled into their own wave) is deliberately NOT the same as plan order; do not
# describe it as plan order. The choice is a pure function of (failing set, wave
# order): same inputs, same answer, no round number in it. It is re-evaluated
# every self-heal round against THAT round's failing set (see
# self_heal_full_suite), so if a heal clears one owner and exposes another, the
# next round follows the evidence instead of grinding the first ticket. The
# earliest-wave owner is preferred because a later wave's failure is more often
# downstream of it than the reverse.
#
# Prints "<ticketId>\t<basis>"; basis is one of:
#   authored-failing-suite  — this ticket's own recorded tests are the failing ones
#   unresolved-last-built   — NO failing suite could be attributed to a ticket, so
#                             this is merely the last ticket built, NOT a culprit
#   none                    — nothing to pick from at all
#
# GLOBBING IS DISABLED while the id lists are split (S157 D9). The inputs are
# whitespace-separated ticket ids and word-splitting IS wanted, but pathname
# expansion is not: with `set -f` off, a stray `*` in a failing list expanded
# against the CWD and the function returned a FILENAME as the culprit id.
selfheal_regressor() { # failing-ids  ordered-ids → "<id>\t<basis>"
  local failing="$1" ordered="$2" id f last="" out=""
  local noglob=0; case "$-" in *f*) noglob=1 ;; esac
  set -f
  for id in $ordered; do
    for f in $failing; do
      [ "$id" = "$f" ] && { out="$id	authored-failing-suite"; break; }
    done
    [ -n "$out" ] && break
  done
  # A failing id the ordered list does not contain is still honest ownership.
  if [ -z "$out" ]; then
    for f in $failing; do out="$f	authored-failing-suite"; break; done
  fi
  if [ -z "$out" ]; then
    for last in $ordered; do :; done
    [ -n "$last" ] && out="$last	unresolved-last-built"
  fi
  [ "$noglob" = 1 ] || set +f
  [ -n "$out" ] || out="	none"
  printf '%s\n' "$out"
}

# The premise line that opens the reconcile brief / the human escalation. Says
# EXACTLY what the harness knows, and — when it knows nothing — says that plainly
# instead of dressing the last-built ticket up as a culprit.
#
# S157 D10: it must not garble on inputs it should never receive. An EMPTY id
# cannot be dressed in a sentence about "%s's tests" (that printed "` AUTHORED
# the failing test(s) … and 's did not pass`"), and an unknown basis must not
# silently DROP an id the caller is holding — both degrade to naming what is
# actually known.
selfheal_attribution_note() { # regressor basis
  local id="${1:-}" basis="${2:-}"
  if [ -z "$id" ]; then
    printf 'ATTRIBUTION: UNRESOLVED — the harness could not name any ticket for this regression (no ticket id was resolved). Treat the failure output below as the only evidence.\n'
    return 0
  fi
  case "$basis" in
    authored-failing-suite)
      printf 'ATTRIBUTION: %s AUTHORED the failing test(s) — the full-suite gate re-ran every ticket'"'"'s own recorded tests and %s'"'"'s did not pass. That is ownership of the broken suite, NOT proof that %s'"'"'s own code is at fault: the break may come from another change the test now runs against. Diagnose from the failure output before assuming.\n' "$id" "$id" "$id" ;;
    unresolved-last-built)
      printf 'ATTRIBUTION: UNRESOLVED — the harness could NOT determine which ticket owns the failing test(s) (no failing suite was attributed to a ticket). %s is simply the LAST ticket built; it is NOT a proven culprit and may have nothing to do with the failure. Treat the failure output below as the only evidence.\n' "$id" ;;
    *)
      printf 'ATTRIBUTION: UNRECOGNISED BASIS "%s" — the harness selected %s but cannot say on what grounds, so treat that id as UNVERIFIED and the failure output below as the only evidence.\n' "$basis" "$id" ;;
  esac
}

escalate_full_suite_regression() { # reason  ordered ticketId...
  local reason="$1"; shift
  local ordered="$*"
  # S157: the ticket to name is the one that AUTHORED the failing suite (or, when
  # ownership could not be resolved, the last built — labelled as exactly that).
  # Prefer the pick self-heal already made so the escalation and the reconcile
  # briefs cannot disagree about who was worked on. Since D3 that pick is the
  # LAST round's, made from the same gate run that produced `$reason` — so the
  # culprit named below and the victims sed'd out of the reason are from one
  # round, not two (they used to be able to diverge).
  local regressor="${SELFHEAL_REGRESSOR:-}" basis="${SELFHEAL_REGRESSOR_BASIS:-}" pick
  if [ -z "$regressor" ]; then
    pick="$(selfheal_regressor "${FULL_SUITE_REGRESSED:-}" "$ordered")"
    regressor="${pick%%$'\t'*}"; basis="${pick#*$'\t'}"; basis="${basis%%$'\n'*}"
  fi
  local regressed_ids; regressed_ids="$(printf '%s\n' "$reason" \
    | sed -n 's/.*no longer pass against the fully-built repo: \([^.]*\)\..*/\1/p' | head -1)"
  local victims; victims="$(tickets_to_issues $regressed_ids)"
  local culprit; culprit="$(tickets_to_issues "$regressor")"
  local summary
  # S157 × #93: AN ENVIRONMENT FAULT READS AS ONE. The generic "a change conflicts
  # with the rest of the branch" copy is actively misleading for a toolchain
  # fault — it points a human at code when the repair is provisioning, and it
  # claims the harness "could not auto-reconcile" something it deliberately never
  # tried. Say plainly what it is, and name the repair the gate already
  # identified. This branch is FIRST so neither of the regression phrasings below
  # can capture the case.
  if [ "$basis" = environment-fault ] || [ -n "${FULL_SUITE_ENV_FAULT:-}" ]; then
    summary="The test suite could not be re-run against a trustworthy dependency environment, so the harness cannot tell whether anything regressed — this is a TOOLCHAIN fault, not broken code, and no ticket is implicated. No worker was dispatched, because no edit to any ticket can clear a stale toolchain: repair the provisioning (\`lcars update\` reinstalls when a worktree's lockfile diverges from the shared install), then run the mission again. The full diagnosis is below."
  # S157: no "the fix for X re-broke a test from Y" — that named a cause the gate
  # never established. Say what happened, who owns the broken test, and what the
  # harness tried.
  elif [ -n "$victims" ] && [ "$basis" = authored-failing-suite ]; then
    summary="A test that was green when it was built no longer passes on the branch — $victims. The harness's last reconcile attempt went to $culprit (the ticket that wrote a failing test) and did not clear it, and it has NOT established which change caused the break. Reply with how to reconcile, send the mission back to re-fix, or drop one."
  elif [ -n "$victims" ]; then
    summary="A test that was green when it was built no longer passes on the branch — $victims. The harness could not work out which ticket owns the failing test, and its reconcile attempts did not clear it. Reply with how to reconcile, send the mission back to re-fix, or drop one."
  else
    summary="A change conflicts with the rest of the branch and the harness could not auto-reconcile it. Reply with how to reconcile, or send the mission back to re-fix."
  fi

  local q; q="$(mktemp)"
  printf '%s\n' "$reason" >"$q"
  local esctype="regression"
  [ "$basis" = environment-fault ] || [ -n "${FULL_SUITE_ENV_FAULT:-}" ] && esctype="environment"
  LCARS_PENDING_HUMAN_SUMMARY="$summary" \
  LCARS_PENDING_ESCALATION_TYPE="$esctype" \
  LCARS_PENDING_TECHNICAL_DETAIL="$reason" \
    write_pending "$q" "implement"
  rm -f "$q"
  state_set_raw awaitingHuman true
  state_set_str pendingQuestion "$summary"
  # In-flight stage label (implement) first, THEN the awaiting-human overlay, so
  # the parked card sits squarely in the Implement column (mirror validate-pause).
  gh_relabel "lcars:implement lcars:awaiting-human" ""

  local what="full-suite regression — self-heal exhausted"
  if [ "$esctype" = environment ]; then
    what="full-suite gate — environment fault, self-heal SKIPPED (no ticket to dispatch)"
  fi
  emit_event gate implement "$what, awaiting your answer: $summary" \
    "phase=full-suite-gate"

  echo "IMPLEMENT: $what, flagged the human"
  printf '%s\n' "$summary"
  echo "  Stage: implement (awaiting-human). Resolve with \`lcars respond $MISSION_ID\`."
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
}

# --- BUG-029: self-heal a full-suite regression before escalating -----------
# Auto-iterate the regressing ticket's unified TDD worker (S157: the ticket that
# AUTHORED the failing suite — see selfheal_regressor — not the last one built)
# with a harness-authored reconcile instruction, re-running the full-suite gate
# after each attempt, up to a cap. Reuses the EXISTING implement-ticket
# re-dispatch path (S133: the fresh worker re-proves the S132 gates on the
# updated tip), mirroring the S76 reconcile / same-file rebuild loops.
# Returns 0 once every suite passes again (healed), non-zero when the cap is hit
# (caller escalates). The last failing reason is written to $SELFHEAL_LAST_REASON.
SELFHEAL_CAP="${LCARS_SELFHEAL_CAP:-3}"
case "$SELFHEAL_CAP" in ''|*[!0-9]*) SELFHEAL_CAP=3 ;; esac
SELFHEAL_LAST_REASON=""
SELFHEAL_REGRESSOR=""        # S157: the ticket self-heal chose, and WHY it chose it
SELFHEAL_REGRESSOR_BASIS=""
self_heal_full_suite() { # reason  ordered ticketId...
  local reason="$1"; shift
  local ordered="$*"
  SELFHEAL_LAST_REASON="$MISSION_DIR/selfheal-last-reason.txt"
  printf '%s\n' "$reason" >"$SELFHEAL_LAST_REASON"

  # S157 × #93: AN ENVIRONMENT FAULT IS NOT SELF-HEALABLE. When the gate reached
  # a stale-dependency or unprovisioned-environment diagnosis it attributed the
  # break to NO ticket, because none is responsible — the suites were re-run
  # against the wrong dependency set. Dispatching a worker there cannot succeed:
  # no edit to any ticket clears a stale toolchain, so every session is spent
  # re-solving a solved problem, which is the exact failure #93 exists to end.
  # Escalate immediately with the diagnosis the gate already produced (it names
  # `lcars update` as the repair) instead of burning the cap first.
  #
  # KEYED ON THE FAULT, NOT ON EMPTINESS. A regression whose OWNER could not be
  # resolved also leaves the failing set empty, and that case must still reach
  # selfheal_regressor and heal on its `unresolved-last-built` basis. The two are
  # different facts and are tested as different cases (proof-gates Q3a vs V3).
  if [ -n "${FULL_SUITE_ENV_FAULT:-}" ]; then
    SELFHEAL_REGRESSOR=""; SELFHEAL_REGRESSOR_BASIS="environment-fault"
    emit_event selfheal_skipped implement \
      "self-heal SKIPPED — the full-suite gate diagnosed an environment fault (${FULL_SUITE_ENV_FAULT}), which attributes to no ticket and no worker edit can clear; escalating with the diagnosis" \
      "fault=${FULL_SUITE_ENV_FAULT}" || :
    return 1
  fi

  # S157: hand the reconcile to the ticket that AUTHORED the failing suite, not to
  # whoever landed last. `failing` starts from the gate run that just failed and is
  # REFRESHED at the bottom of every round from that round's own gate run.
  local failing="${FULL_SUITE_REGRESSED:-}"

  # Resolve the worktree base + branch the same way cmd_implement's rebuild does so
  # the re-dispatched implementer composes on the CURRENT mission-branch tip.
  local branch; branch="$(json_str "$STATE" branch)"
  local wt_base="$MISSION_DIR/selfheal-wt"

  local round=0 fssig regressor basis pick attribution
  while [ "$round" -lt "$SELFHEAL_CAP" ]; do
    round=$((round + 1))
    # S157 D3: RE-PICK EVERY ROUND, from THIS round's failing set. Both halves of
    # the brief have to come from the same round: the reason below is rewritten
    # each iteration, so a regressor (and an attribution line) fixed before the
    # loop would, from round 2 on, name one ticket above a failure belonging to
    # another — the exact wrong-premise handoff this session exists to kill. It
    # also means a heal that clears one owner's suite and exposes a second moves
    # the next round's work to that second owner instead of grinding the first.
    pick="$(selfheal_regressor "$failing" "$ordered")"
    regressor="${pick%%$'\t'*}"; basis="${pick#*$'\t'}"
    SELFHEAL_REGRESSOR="$regressor"; SELFHEAL_REGRESSOR_BASIS="$basis"
    [ -n "$regressor" ] || return 1
    attribution="$(selfheal_attribution_note "$regressor" "$basis")"
    emit_event selfheal_attribution implement \
      "round $round: full-suite regression attributed to $regressor ($basis)" \
      "ticket=$regressor" "round=$round" || :
    emit_event selfheal implement "self-heal round $round/$SELFHEAL_CAP — re-running $regressor's implementer to reconcile the regression" \
      "ticket=$regressor" "round=$round"

    # Re-dispatch ONLY the regressing ticket's unified worker with the reconcile
    # feedback (S133: the fresh worker re-proves every gate on the updated tip;
    # an undeclared weakening of the regressed test is still blocked by the
    # declared-edits guard + the pre-merge drift check).
    local irc=0
    rm -f "$(ticket_dir "$regressor")/.build-rc" "$(ticket_dir "$regressor")/.commit-sha" "$(ticket_dir "$regressor")/.commit-base" 2>/dev/null
    LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" \
    LCARS_TICKET_WT_BASE="$wt_base" LCARS_TICKET_BRANCH="$branch" \
    LCARS_SELFHEAL_FEEDBACK="$attribution
$(cat "$SELFHEAL_LAST_REASON")" \
      bash "$SELF" implement-ticket --mission "$MISSION_ID" --ticket "$regressor" >/dev/null 2>&1 || irc=$?

    # A flagged ticket (its own session cap) set awaitingHuman in shared state —
    # the per-ticket cap already handled it; stop self-healing here.
    if [ "$(json_raw "$STATE" awaitingHuman)" = "true" ]; then
      emit_event selfheal implement "self-heal round $round flagged the ticket's own attempt cap — stopping self-heal" \
        "ticket=$regressor" "round=$round"
      return 1
    fi

    # Cherry-pick the rebuild's fresh commit onto the mission branch (the worktree
    # build committed on a detached HEAD), exactly like the same-file rebuild path,
    # so the full-suite gate re-runs against the integrated tip. S111: via the
    # SAME mutex-protected landing replay every other commit uses — the old inline
    # `checkout $branch` here is what left the captain's checkout stranded on the
    # mission branch after every heal (root-tree sovereignty).
    local sha; sha="$(cat "$(ticket_dir "$regressor")/.commit-sha" 2>/dev/null || true)"
    if [ -n "$sha" ] && [ -n "$branch" ] && "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch"; then
      replay_ticket_commit "$branch" "$sha" "$regressor" \
        || emit_event selfheal implement \
             "self-heal round $round: the rebuilt commit did not land cleanly (${REPLAY_FAIL_REASON:-cherry-pick failed}) — the full-suite retest will judge the unchanged tip" \
             "ticket=$regressor" "round=$round"
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
    # S157 D3: the reason and the attribution must stay in step — refresh the
    # failing set from the gate run that produced the reason just stored.
    failing="${FULL_SUITE_REGRESSED:-}"
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

    # BUG-029: SELF-HEAL BEFORE escalating. A full-suite regression is usually a
    # MECHANICALLY-RECONCILABLE failure — a test that was green when its ticket was
    # built no longer passes on the assembled branch — exactly the kind of fix an
    # implementer can be told to make (the captain otherwise hand-types "reconcile
    # so test T passes; don't touch the locked contract"). So auto-iterate the
    # implementer of the ticket that AUTHORED the failing suite (S157 — the gate
    # names it; the old rule guessed the last-built one) with that harness-authored
    # feedback, re-run the full-suite gate, and escalate only AFTER the cap. This
    # reuses the SAME implement-ticket re-dispatch machinery the S76 reconcile /
    # same-file rebuild already drive (S133: the fresh unified worker re-proves
    # the gates; an undeclared test weakening is still blocked). The full-suite
    # gate (BUG-013) is never weakened: it must still pass for the loop to clear.
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
# S134 — the CONTRACT-CHANGES readout. Given the mission's ordered ticket ids,
# reads each ticket's S133 proof artifacts (result.json v2, flip-flop.json,
# test-edits.json) and prints the per-ticket flip-flop verdict + the mission's
# CONTRACT AMENDMENTS block (declared {path, reason} edits, verbatim). It prints
# NOTHING for a pre-S133 mission (no flip-flop.json / test-edits.json on ANY
# ticket) so that readout is BYTE-IDENTICAL to before this round. The board
# renders the same shape (local_adapter `_ticket_proof`), so CLI ↔ UI agree.
verify_contract_readout() { # ordered ticket ids as args
  [ "$#" -gt 0 ] || return 0
  "${LCARS_PYTHON_BIN:-python3}" - "$MISSION_DIR" "$@" <<'PYEOF'
import json, os, sys
mdir = sys.argv[1]; ids = sys.argv[2:]
def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception:
        return None
rows = []; proofed = False
for tid in ids:
    td = os.path.join(mdir, "tickets", tid)
    ff = load(os.path.join(td, "flip-flop.json"))
    te = load(os.path.join(td, "test-edits.json"))
    res = load(os.path.join(td, "result.json"))
    if not isinstance(ff, dict) and not isinstance(te, list):
        rows.append((tid, None)); continue          # pre-S133 ticket
    proofed = True
    edits = te if isinstance(te, list) else (
        (res.get("testEdits") if isinstance(res, dict) else []) or [])
    edits = [e for e in edits if isinstance(e, dict) and e.get("path")]
    # S157: "new/changed" must count CHANGED files too. A repair declares its work
    # in testEdits, not newTests, so a repair-only ticket used to read
    # "0 new/changed test(s)" beside a PROVEN chip — which looks like a ticket
    # that touched no tests at all, next to a REPAIRED block saying it did.
    new = 0
    if isinstance(res, dict) and isinstance(res.get("newTests"), list):
        new = len([p for p in res["newTests"] if isinstance(p, str) and p])
    new += len({e["path"] for e in edits if e.get("path")})
    decl = res.get("flipFlop") if isinstance(res, dict) else None
    ffv = ff.get("verdict") if isinstance(ff, dict) else None
    if decl == "not-applicable" or ffv == "skipped":
        verdict = "N/A"
        reason = (res.get("flipFlopReason") if isinstance(res, dict) else None) \
            or (ff.get("reason") if isinstance(ff, dict) else "") or ""
    elif ffv == "pass":
        verdict, reason = "PROVEN", ""
    elif ffv in ("fail", "inconclusive"):
        verdict = ffv.upper()
        reason = (ff.get("reason") if isinstance(ff, dict) else "") or ""
    else:
        verdict, reason = None, ""
    # S157: was this ticket certified as a REPAIR of a pre-existing test — i.e.
    # did the parent leg run the parent's OWN committed copy of some file? The
    # harness deliberately does NOT try to prove such an edit was honest (that
    # guard was tried, broken five times, and ruled out), so the human has to see
    # it. flip-flop.json records the per-file provenance; anything sourced
    # "parent-own" is a repair, and the file is named below.
    repaired = []
    pleg = ff.get("parentLeg") if isinstance(ff, dict) else None
    if isinstance(pleg, dict):
        for srow in (pleg.get("sources") or []):
            if isinstance(srow, dict) and srow.get("source") == "parent-own" and srow.get("path"):
                repaired.append(srow["path"])
    rows.append((tid, {"new": new, "edits": edits, "verdict": verdict,
                       "reason": reason, "repaired": repaired}))
if not proofed:
    sys.exit(0)                                       # byte-identical: print nothing
out = ["  Proof of work:"]
for tid, p in rows:
    if p is None:
        out.append("    - %s: no proof artifacts on file" % tid); continue
    chip = "flip-flop %s" % (p["verdict"] or "-")
    if p["verdict"] == "N/A" and p["reason"]:
        chip += " (%s)" % p["reason"]
    glyph = "✓" if p["verdict"] == "PROVEN" else "-"
    out.append("    %s %s -- %s · %d new/changed test(s)" % (glyph, tid, chip, p["new"]))
# S157: REPAIRS OF PRE-EXISTING TESTS, called out for the human. A repair is
# certified as "this file was already failing at the parent and passes now" — the
# harness does not, and no longer tries to, establish that nothing was quietly
# removed while it was being fixed. So the reviewer is told exactly which
# pre-existing test files a ticket rewrote, and pointed at the diff.
repairs = [(tid, path) for tid, p in rows if p for path in p.get("repaired") or []]
if repairs:
    out.append("  REPAIRED PRE-EXISTING TESTS (review these diffs):")
    for tid, path in repairs:
        out.append("    ⟲ %s · %s" % (tid, path))
    out.append("      These files were already FAILING at the parent commit and pass now.")
    out.append("      The harness checked the runner did not execute fewer tests than before,")
    out.append("      but it does NOT verify that nothing was removed while they were fixed.")
amend = [(tid, e) for tid, p in rows if p for e in p["edits"]]
if amend:
    out.append("  CONTRACT AMENDMENTS (declared test edits):")
    for tid, e in amend:
        out.append("    ✎ %s · %s -- %s" % (tid, e.get("path"), e.get("reason", "") or ""))
else:
    out.append("  Contract amendments: none -- no existing tests were adapted.")
sys.stdout.write("\n".join(out) + "\n")
PYEOF
}

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
  local total=0 green=0 nwaves=0 w id rf attempts ordered_ids=""
  while IFS=$'\t' read -r w id; do
    [ -n "$id" ] || continue
    total=$((total + 1))
    ordered_ids="${ordered_ids:+$ordered_ids }$id"
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

  # S134: the contract-changes readout (per-ticket flip-flop verdict + declared
  # test edits). Prints NOTHING for a pre-S133 mission, so its readout is
  # byte-identical to before this round.
  # shellcheck disable=SC2086
  verify_contract_readout $ordered_ids

  # S113: show the ACTUAL cost beside the ESTIMATE (display-only — actuals are
  # captured by S112 into usage.json; the estimate is never touched). Present
  # ONLY when this mission has a usage.json with records; absent usage.json → NO
  # line, so a pre-round / pre-verify mission's readout is byte-identical to
  # before. Unit tracks the mission's billing unit (usd / premium reqs), matching
  # the estimate readout so EST and ACTUAL are same-unit.
  local est_f="$MISSION_DIR/estimate.json" usage_f="$MISSION_DIR/usage.json"
  if [ -f "$est_f" ] && [ -f "$usage_f" ]; then
    local act_c; act_c="$(usage_actual_compact "$usage_f")"
    if [ -n "$act_c" ]; then
      local cli; cli="$(json_scoped_str "$est_f" "cost.cli")"
      [ -n "$cli" ] || cli="${LCARS_WORKER_CLI:-$(basename "${WORKER_BIN:-claude}")}"
      echo "  Cost: EST $(render_cost_compact "$est_f" "$cli") → ACTUAL $act_c"
    fi
  fi

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

# reconcile_unpushed_count <branch> — how many commits <branch> has that
# origin/<branch> does not. 0 when there is no remote branch to compare against,
# or when the count cannot be determined — "0" always means "nothing provably at
# risk", so a failure to measure can never authorise a destructive reset.
reconcile_unpushed_count() { # branch → count
  local b="${1:-}" n
  [ -n "$b" ] || { printf '0'; return 0; }
  "$GIT_BIN" show-ref --verify --quiet "refs/remotes/origin/$b" || { printf '0'; return 0; }
  n="$("$GIT_BIN" rev-list --count "origin/$b..$b" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# reconcile_unpushed_work_count <branch> — of those local-only commits, how many
# are LCARS TICKET WORK.
#
# This is the distinction that decides whether the branch may be reset, and it
# has to be exactly right in BOTH directions:
#
#   • A dead reconcile attempt is what BUG-077 was written for. Reconcile builds
#     its attempt with `git merge --no-edit "$base_ref"`, so the artifact left on
#     a killed retry is a MERGE (or a hand-made resolution) — it carries no
#     ticket signature, is genuinely disposable, and still resets exactly as
#     before.
#   • A ticket commit is authored by commit_ticket, which always writes the
#     subject "lcars(<mission-id>) t-NNN: …". A logged bug's fix is cherry-picked
#     onto the parent branch and the cherry-pick PRESERVES that subject, so the
#     fixes that were destroyed in the field are precisely the commits this
#     recognises.
#
# Keying on LCARS's own commit-message contract (rather than on merge-ness) means
# no existing BUG-077 assertion changes meaning: a non-ticket local-only commit
# is still discarded, a ticket commit never is.
reconcile_unpushed_work_count() { # branch → count
  local b="${1:-}" n
  [ -n "$b" ] || { printf '0'; return 0; }
  "$GIT_BIN" show-ref --verify --quiet "refs/remotes/origin/$b" || { printf '0'; return 0; }
  n="$("$GIT_BIN" log --format=%s "origin/$b..$b" 2>/dev/null | grep -c '^lcars(')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# reconcile_sync_local_branch <branch> — bring the LOCAL branch into agreement
# with the remote PR head WITHOUT ever destroying committed work.
#
# BUG-077 introduced a blunt `git branch -f "$BRANCH" "origin/$BRANCH"` here so a
# killed/retried reconcile could not leave the local tip diverged and jam the
# eventual push. That is right when the local-only commits are a dead attempt's
# merge commit. It is catastrophic when they are real work — and it destroyed
# real work in the field.
#
# MISSION-LOG BUG FIXES ARE EXACTLY THAT WORK. A logged bug never opens its own
# PR: its fix is cherry-picked onto the PARENT's branch and rides the parent's
# PR (see fold_one_child in skills/lcars-resolve-logs). Until the parent next
# pushes, those commits exist ONLY locally. Observed live (DX-Scorecard,
# 2026-07-28): three gate-verified bug fixes were cherry-picked onto the parent
# branch, the parent re-entered reconcile 109 seconds later because main had
# moved 8 commits ahead, and the reset moved the branch back to the remote head
# — which was precisely the chain's base. All three commits became unreachable
# in one command. The reconcile then re-tested the PARENT's ticket, went green
# (the bug fixes' own tests had been discarded along with their code, so nothing
# was left to fail), and the PR merged carrying none of it. Silently.
#
# THE RULE: divergence is resolved by PUBLISHING local work, not by deleting it.
#   local has commits the remote lacks → PUSH them. Divergence is genuinely gone
#                                        (local == remote) and nothing is lost.
#   the push fails                     → leave the branch ALONE and say so; a
#                                        jammed push is recoverable, deleted
#                                        commits are not.
#   nothing local-only                 → reset exactly as BUG-077 intended.
#
# Best-effort throughout: never aborts the caller.
reconcile_sync_local_branch() { # branch
  local b="${1:-}"
  [ -n "$b" ] || return 0
  "$GIT_BIN" show-ref --verify --quiet "refs/remotes/origin/$b" || return 0
  local local_tip remote_tip
  local_tip="$("$GIT_BIN" rev-parse "$b" 2>/dev/null)"
  remote_tip="$("$GIT_BIN" rev-parse "origin/$b" 2>/dev/null)"
  [ -n "$remote_tip" ] || return 0
  [ "$local_tip" = "$remote_tip" ] && return 0

  local unpushed work
  unpushed="$(reconcile_unpushed_count "$b")"
  work="$(reconcile_unpushed_work_count "$b")"
  if [ "$work" -gt 0 ]; then
    if "$GIT_BIN" push origin "$b" >/dev/null 2>&1; then
      emit_event reconcile_local_commits_pushed verify \
        "re-entry: '$b' carried $work ticket commit(s) (of $unpushed local-only) the remote had never seen — a logged bug's fix rides the parent's PR and is local-only until this push. PUSHED them instead of resetting, so divergence is resolved with nothing discarded"
    else
      emit_event reconcile_reset_skipped verify \
        "re-entry: '$b' carries $work local-only ticket commit(s) and they could NOT be pushed — REFUSING to reset to the remote head, because that would delete committed, gate-verified work (this is how three mission-log fixes were lost). Proceeding from the local tip; push '$b' by hand, then re-run."
    fi
    return 0
  fi

  # Nothing local-only to lose → the BUG-077 reset, behaviour unchanged.
  # S111 (root-tree sovereignty): NEVER detach the captain's checkout to free the
  # ref. A holder is either a stale LCARS worktree (prune + retry) or the
  # CAPTAIN's own checkout — in that case SKIP with a loud event rather than
  # yanking their HEAD out from under them.
  if "$GIT_BIN" branch -f "$b" "origin/$b" >/dev/null 2>&1; then
    emit_event reconcile_reset verify \
      "re-entry: reset local '$b' to the remote PR head ($(printf '%s' "$remote_tip" | cut -c1-7)) before re-merging — avoids divergence (no local-only commits to lose)"
    return 0
  fi
  "$GIT_BIN" worktree prune >/dev/null 2>&1 || :
  if "$GIT_BIN" branch -f "$b" "origin/$b" >/dev/null 2>&1; then
    emit_event reconcile_reset verify \
      "re-entry: reset local '$b' to the remote PR head ($(printf '%s' "$remote_tip" | cut -c1-7)) after pruning a stale worktree"
    return 0
  fi
  local rr_holder
  rr_holder="$( cd "$REPO_ROOT" && "$GIT_BIN" worktree list --porcelain 2>/dev/null \
    | awk -v bb="branch refs/heads/$b" '
        /^worktree /{p=substr($0,10)}
        $0==bb{print p; exit}' )"
  emit_event reconcile_reset_skipped verify \
    "re-entry: could NOT reset '$b' to the remote PR head — the branch is checked out at ${rr_holder:-an unknown worktree} (likely your own checkout). Proceeding from the local tip; if approve later rejects the push as non-fast-forward, switch that checkout off the branch and re-run."
  return 0
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
     && "$GIT_BIN" fetch origin "$BRANCH" --quiet 2>/dev/null; then
    reconcile_sync_local_branch "$BRANCH"
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
  # S111 (root-tree sovereignty): the old BUG-054 pre-detach of $REPO_ROOT is
  # GONE — LCARS no longer parks any tree on the mission branch (the heal lands
  # via the mutex-protected landing replay, which cleans up after itself), so the
  # attached cut below succeeds on its own. If it still fails, the holder is the
  # CAPTAIN's checkout or a stale tree — the recovery path below prunes, retries,
  # and escalates with the holder named; it never touches the captain's HEAD.
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
      local rc_holder
      rc_holder="$( cd "$REPO_ROOT" && "$GIT_BIN" worktree list --porcelain 2>/dev/null \
        | awk -v b="branch refs/heads/$BRANCH" '
            /^worktree /{p=substr($0,10)}
            $0==b{print p; exit}' )"
      local wt_diag="Can't reconcile with '$BASE' — the mission branch '$BRANCH' is checked out at ${rc_holder:-another worktree}${rc_holder:+ (likely your own checkout)}. Switch that checkout to another branch (or \`git worktree remove\` a stale tree, then \`git worktree prune\`) and re-run. LCARS reconciles in its own worktree and never touches your checkout."
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
#                     >  the MISSION's recorded workerBin (state.json)
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
  # THE MISSION'S OWN PIN — ahead of host detection. A mission records the engine
  # it was filed with in state.json (`lcars file --engine copilot` → workerBin).
  # Until now the resolver never read it, so the engine was re-DECIDED from the
  # ambient terminal on every invocation: a mission filed and driven under Copilot
  # that was later RESUMED from a Claude Code session (CLAUDECODE=1) silently
  # re-homed onto billed claude mid-flight, with the pin sitting right there in
  # state.json being ignored. Observed live: 7 workers and $11.39 billed to the
  # wrong engine after a resume from the wrong terminal, with no warning — the
  # spend is the ONLY symptom, which is why detection must never outrank an
  # explicit record. An explicitly recorded engine beats a guess; env and config
  # (both deliberate operator acts) still outrank the mission, so an operator can
  # still move a mission on purpose. Several callers set MISSION_DIR but not STATE,
  # so derive the path defensively and stay silent when there is no mission.
  local statef="${STATE:-}"
  [ -n "$statef" ] || { [ -n "${MISSION_DIR:-}" ] && statef="$MISSION_DIR/state.json"; }
  local misbin=""
  [ -n "$statef" ] && [ -f "$statef" ] && misbin="$(json_str "$statef" workerBin)"
  if [ -n "$misbin" ]; then
    WORKER_BIN="$misbin"; WORKER_BIN_SRC="mission"; return 0
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
    implement-tdd)                                printf 'implement' ;;
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

# The tier that will ACTUALLY RUN for (cli, logical tier) — the honest answer to
# "what model does this stage get?" (S147 DEFECT-3).
#
# WHY THIS EXISTS. The estimator writes a LOGICAL tier per stage, and every
# captain-facing surface printed that tier verbatim. On copilot that is a LIE:
# alias_for_tier pins BOTH tiers to claude-opus-4.8 (the `create`-tool safety
# policy above — correct, and NOT changed by this function), so a copilot
# captain was shown "implement=Sonnet" while all five stages resolved opus, and
# the cost band was priced at sonnet rates for an opus run. This is a REPORTING
# fix only: nothing here influences which model is spawned.
#
# It derives the answer FROM alias_for_tier rather than re-stating the policy, so
# there is still exactly ONE home for "copilot is opus-safe by default" and the
# two can never drift. That also means a repo's `modelAliases.<cli>.<tier>`
# override is honoured here for free — a repo that maps copilot's sonnet tier
# back to a real Sonnet model gets a readout that says Sonnet.
#
# ENGINES STAY SEPARATE: claude's arm resolves 'sonnet'→"sonnet"/'opus'→"opus",
# so claude surfaces are byte-identical to before. No engine learns about the
# other; each is classified through its own alias arm.
effective_tier_for_cli() { # cli logical-tier → the tier that really runs
  local cli="$1" tier="$2" m
  m="$(alias_for_tier "$cli" "$tier")"
  # No mapping at all ⇒ the legacy no-`--model` argv: the CLI's own default runs
  # and we have nothing better to claim than the logical tier.
  [ -n "$m" ] || { printf '%s' "$tier"; return 0; }
  case "$m" in
    *opus*)   printf 'opus' ;;
    *sonnet*) printf 'sonnet' ;;
    *haiku*)  printf 'haiku' ;;
    *)        printf '%s' "$tier" ;;   # an unrecognised alias: don't invent a tier
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
    # Mirror the real call sites (spawn paths set MISSION_DIR the same way) so
    # `--mission <id>` makes the mission's own pin participate in resolution.
    [ -n "${MISSION_ID:-}" ] && MISSION_DIR="$gitdir/lcars/missions/$MISSION_ID"
  fi
  resolve_worker
  printf 'WORKER-RESOLVED bin=%s binsrc=%s model=%s modelsrc=%s\n' \
    "$(basename "$WORKER_BIN")" "$WORKER_BIN_SRC" \
    "${WORKER_MODEL:--}" "$WORKER_MODEL_SRC"
}

# === USAGE CAPTURE (session 112) ============================================
# ACTUAL per-spawn usage for a cold worker. After the worker exits, read the
# CLI's OWN on-disk session artifact (keyed by the minted --session-id — a SIDE
# channel, never `.worker.out`) and append ONE record to $MISSION_DIR/usage.json
# (JSONL, one record per spawn — a sibling of estimate.json; the estimate is
# NEVER mutated). Cost is computed BY CODE from pricing.json rates (the same
# json_scoped_num lookups cost_compute uses — pricing numbers are not
# reimplemented here). Capture is best-effort telemetry: it NEVER fails a stage;
# a miss degrades to a `source:"unavailable"` record. Mechanism + schema live in
# skills/lcars-run/USAGE-CAPTURE-SPIKE.md.

# Is usage capture enabled? Env LCARS_USAGE_CAPTURE (1/on/true ⇢ on, 0/off/false
# ⇢ off) wins; else config.json `usageCapture:false` disables; DEFAULT ON. When
# on, worker_spawn also needs `uuidgen` to mint the correlation key (it skips
# minting — hence capture — if uuidgen is unavailable, so argv stays unchanged).
usage_capture_enabled() {
  case "${LCARS_USAGE_CAPTURE:-}" in
    0|off|OFF|false|FALSE|no|NO)  return 1 ;;
    1|on|ON|true|TRUE|yes|YES)    return 0 ;;
  esac
  if [ -n "${LCARS_CFG:-}" ] && [ -f "${LCARS_CFG:-}" ]; then
    case "$(json_scoped_str "$LCARS_CFG" "usageCapture")" in
      false|off|0|no) return 1 ;;
    esac
  fi
  return 0
}

# A model string (from the artifact) → the logical pricing tier. Unknown ⇒ opus
# (the safe default; LCARS runs opus by default on both engines).
usage_model_tier() { case "$1" in *sonnet*|*Sonnet*) printf 'sonnet' ;; *) printf 'opus' ;; esac; }

# Parse the CLI's on-disk session artifact for <session-id>. Emits ONE pipe line:
#   source|model|inputTokens|outputTokens|cacheReadTokens|cacheWriteTokens|premiumRequests
# (premiumRequests empty for claude). Non-zero + no output when nothing is found.
# Artifact roots are env-overridable so tests point capture at a stub location:
#   claude  : $LCARS_CLAUDE_PROJECTS_DIR (default ~/.claude/projects); glob **/<id>.jsonl
#   copilot : $LCARS_COPILOT_SESSION_DIR (default ~/.copilot/session-state)/<id>/events.jsonl
usage_parse_artifact() { # engine session-id
  "${LCARS_PYTHON_BIN:-python3}" - "$1" "$2" <<'PY'
import json,sys,os,glob
engine=sys.argv[1]; sid=sys.argv[2]
def geti(d,k):
    try: return int(d.get(k,0) or 0)
    except Exception: return 0
if engine=='claude':
    root=os.environ.get('LCARS_CLAUDE_PROJECTS_DIR') or os.path.join(os.path.expanduser('~'),'.claude','projects')
    m=glob.glob(os.path.join(root,'**',sid+'.jsonl'),recursive=True)
    if not m: sys.exit(1)
    intok=outtok=crtok=cwtok=0; model=''
    try:
        for line in open(m[0]):
            line=line.strip()
            if not line: continue
            try: d=json.loads(line)
            except Exception: continue
            if d.get('type')!='assistant': continue
            msg=d.get('message') or {}
            u=msg.get('usage') or {}
            intok+=geti(u,'input_tokens'); outtok+=geti(u,'output_tokens')
            crtok+=geti(u,'cache_read_input_tokens'); cwtok+=geti(u,'cache_creation_input_tokens')
            if msg.get('model'): model=msg['model']
    except OSError:
        sys.exit(1)
    if not model and intok==0 and outtok==0: sys.exit(1)
    print('session-transcript|%s|%d|%d|%d|%d|'%(model,intok,outtok,crtok,cwtok))
else:
    root=os.environ.get('LCARS_COPILOT_SESSION_DIR') or os.path.join(os.path.expanduser('~'),'.copilot','session-state')
    path=os.path.join(root,sid,'events.jsonl')
    if not os.path.exists(path): sys.exit(1)
    sd=None
    for line in open(path):
        line=line.strip()
        if not line: continue
        try: d=json.loads(line)
        except Exception: continue
        if d.get('type')=='session.shutdown': sd=d.get('data') or {}
    if sd is None: sys.exit(1)
    intok=outtok=crtok=cwtok=0; model=sd.get('currentModel') or ''
    for mname,mv in (sd.get('modelMetrics') or {}).items():
        u=(mv or {}).get('usage') or {}
        intok+=geti(u,'inputTokens'); outtok+=geti(u,'outputTokens')
        crtok+=geti(u,'cacheReadTokens'); cwtok+=geti(u,'cacheWriteTokens')
        if not model: model=mname
    print('session-state|%s|%d|%d|%d|%d|%d'%(model,intok,outtok,crtok,cwtok,geti(sd,'totalPremiumRequests')))
PY
}

# The post-exit hook (called by worker_spawn). Parse the artifact, compute cost by
# code from pricing.json, append ONE usage.json record, and emit a worker_usage
# event. Always returns 0 — capture is telemetry, never a gate.
usage_capture() { # env-role outdir stage-key cli session-id
  [ -n "${MISSION_DIR:-}" ] || return 0
  local role="$1" outdir="$2" stage="$3" cli="$4" sid="$5"
  local uf="$MISSION_DIR/usage.json"
  local ts; ts="${LCARS_NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)}"
  local parsed; parsed="$(usage_parse_artifact "$cli" "$sid" 2>/dev/null)" || parsed=""
  if [ -z "$parsed" ]; then
    # DEGRADE: the mechanism found nothing. Record it (never a stage failure).
    printf '{"stage":%s,"role":%s,"engine":%s,"sessionId":%s,"source":"unavailable","ts":%s}\n' \
      "$(json_encode_string "$stage")" "$(json_encode_string "$role")" \
      "$(json_encode_string "$cli")" "$(json_encode_string "$sid")" \
      "$(json_encode_string "$ts")" >>"$uf" 2>/dev/null || true
    emit_event worker_usage "$stage" "usage unavailable" engine="$cli" unavailable=1
    return 0
  fi
  local source model intok outtok crtok cwtok premium
  IFS='|' read -r source model intok outtok crtok cwtok premium <<<"$parsed"
  [ -n "$intok" ]  || intok=0;  [ -n "$outtok" ] || outtok=0
  [ -n "$crtok" ]  || crtok=0;  [ -n "$cwtok" ]  || cwtok=0
  [ -n "$premium" ] || premium=0
  local tier; tier="$(usage_model_tier "$model")"
  # --- cost BY CODE, reusing pricing.json rate lookups ----------------------
  local unit="usd" cost="0" costusd="0"
  if [ "$cli" = "copilot" ] && [ "$(copilot_billing_model)" = "legacy" ]; then
    # Legacy premium-request billing: the native unit is premium requests (taken
    # straight from the artifact); USD is the optional $/request overage.
    unit="premiumRequests"
    local overage; overage="$(json_scoped_num "$PRICING_FILE" "copilot.legacy.overagePerRequest")"
    [ -n "$overage" ] || overage=0
    cost="$premium"
    costusd="$(awk -v p="$premium" -v o="$overage" 'BEGIN{printf "%g", p*o}')"
  else
    # Token → USD. claude splits base input from cache (apply cacheRead/Write
    # mults); copilot.usage inputTokens ALREADY includes cache, so no cache mult.
    local scope="claude" inr outr
    [ "$cli" = "copilot" ] && scope="copilot.usage"
    inr="$(json_scoped_num "$PRICING_FILE" "$scope.$tier.inputPerMTok")";  [ -n "$inr" ]  || inr=0
    outr="$(json_scoped_num "$PRICING_FILE" "$scope.$tier.outputPerMTok")"; [ -n "$outr" ] || outr=0
    if [ "$cli" = "copilot" ]; then
      costusd="$(awk -v i="$intok" -v o="$outtok" -v ir="$inr" -v orr="$outr" \
        'BEGIN{printf "%.6f",(i*ir + o*orr)/1000000}')"
    else
      local crmult cwmult
      crmult="$(json_scoped_num "$PRICING_FILE" "claude.cacheReadMult")";  [ -n "$crmult" ] || crmult=0
      cwmult="$(json_scoped_num "$PRICING_FILE" "claude.cacheWriteMult")"; [ -n "$cwmult" ] || cwmult=0
      costusd="$(awk -v i="$intok" -v o="$outtok" -v cr="$crtok" -v cw="$cwtok" \
        -v ir="$inr" -v orr="$outr" -v crm="$crmult" -v cwm="$cwmult" \
        'BEGIN{printf "%.6f",(i*ir + o*orr + cr*ir*crm + cw*ir*cwm)/1000000}')"
    fi
    costusd="$(awk -v v="$costusd" 'BEGIN{printf "%g", v}')"
    cost="$costusd"
  fi
  # --- append ONE record (JSONL) --------------------------------------------
  local rec
  rec="$(printf '{"stage":%s,"role":%s,"engine":%s,"model":%s,"inputTokens":%d,"outputTokens":%d,"cacheReadTokens":%d,"cacheWriteTokens":%d' \
      "$(json_encode_string "$stage")" "$(json_encode_string "$role")" \
      "$(json_encode_string "$cli")" "$(json_encode_string "$model")" \
      "$intok" "$outtok" "$crtok" "$cwtok")"
  [ "$cli" = "copilot" ] && rec="$rec$(printf ',"premiumRequests":%d' "$premium")"
  rec="$rec$(printf ',"sessionId":%s,"source":%s,"ts":%s,"billingUnit":%s,"costUsd":%s,"cost":%s}' \
      "$(json_encode_string "$sid")" "$(json_encode_string "$source")" \
      "$(json_encode_string "$ts")" "$(json_encode_string "$unit")" \
      "$costusd" "$cost")"
  printf '%s\n' "$rec" >>"$uf" 2>/dev/null || true
  emit_event worker_usage "$stage" "usage captured" engine="$cli" \
    inputTokens="$intok" outputTokens="$outtok" cost="$cost" billingUnit="$unit"
  return 0
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
  # USAGE CAPTURE (session 112): when enabled, mint a fresh per-spawn UUID and
  # export it so the adapter adds `--session-id <uuid>` (ONLY then — the no-usage
  # argv stays byte-for-byte). After the worker exits we parse the CLI's own
  # on-disk session artifact keyed by that id and append ONE record to
  # $MISSION_DIR/usage.json. Capture is best-effort telemetry: it NEVER changes
  # the stage's exit status and NEVER fails the stage (a miss ⇒ `unavailable`
  # record). See skills/lcars-run/USAGE-CAPTURE-SPIKE.md.
  local usage_sid=""
  if usage_capture_enabled; then usage_sid="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"; fi
  # HANG-GUARD (BUG-076): wrap the cold-worker spawn so a mid-turn hang (0% CPU,
  # no output, never returns) is auto-killed and the caller's retry loop kicks in.
  # The guard polls the worker's process-group CPU% and the growth of the adapter's
  # $outdir/.worker.out/.err; a slow-but-working worker is left alone. Covers EVERY
  # cold worker (every Stage routes through here). LCARS_WORKER_HANG_SECS=0 disables.
  local spawn_rc=0
  LCARS_WORKER_BIN="$WORKER_BIN" LCARS_WORKER_MODEL="$stage_model" \
    LCARS_WORKER_SESSION_ID="$usage_sid" \
    LCARS_LIVENESS_STAGE="$stage_key" \
    run_worker_hang_guarded "$outdir" \
    bash "$WORKER_ADAPTER" spawn "$cli" "$role" "$outdir" "$prompt" || spawn_rc=$?
  # Post-exit, side-channel usage read. Guarded so a capture bug can never break a
  # Stage: preserve the worker's own exit status ($spawn_rc), swallow capture errors.
  if [ -n "$usage_sid" ]; then
    usage_capture "${LCARS_WORKER_ROLE:-$role}" "$outdir" "$stage_key" "$cli" "$usage_sid" || true
  fi
  return "$spawn_rc"
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
  refuse_if_parked
  require_stage align
  require_worker
  [ -f "$MISSION_DIR/prd.md" ] || die "no prd.md — Align has not produced a PRD for '$MISSION_ID'."

  # IN-FLIGHT STAGE LABEL (CLAUDE.md build item #11). Every other Stage gets its
  # board label from the transition INTO it, because its label matches the stage
  # POINTER. Research is the one Stage whose pointer never says "research" — it
  # runs while the pointer is still "align" and only moves at advance() — so no
  # transition ever applied lcars:research and the Research column was
  # permanently empty. The only writer was the >20-question escalation in
  # cmd_gate, i.e. a card could only reach Research by getting STUCK there.
  #
  # Apply it HERE, the moment Research actually starts. This sits ABOVE the
  # grounding short-circuit on purpose: a logged bug's grounding Research is
  # still Research and belongs on the same generic card (build item #18).
  # advance() drops it again on the way to Validate; the escalation's own
  # relabel re-asserts the same label, so that path is byte-identical.
  #
  # Best-effort like every relabel — gh_relabel never fails a Stage, it only
  # leaves a note. Surface the note NOW rather than at exit, because this
  # command's later exits happen inside the `gate` / `save` subprocesses, which
  # carry their own note; clearing it keeps it from being reprinted downstream.
  gh_relabel "lcars:research" "lcars:align"
  if [ -n "$RELABEL_NOTE" ]; then echo "$RELABEL_NOTE"; RELABEL_NOTE=""; fi

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

  # S166 — MOVE INTO THE MISSION'S OWN CODE before anything is spawned. Every
  # worker below (the question generator AND the per-question fan-out agents,
  # which are subprocesses of this one) inherits this cwd, so the ambient
  # checkout stops being an input to Research at all.
  enter_mission_worktree "$(json_str "$STATE" branch)" research

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

  # S166 — GROUNDING WAS THE THINNEST SPOT, which is backwards. A logged bug's
  # entire job is reasoning about code that already exists, yet the parent's
  # ARTIFACTS arrived reliably (read off disk, by absolute path) while the parent's
  # DELIVERED CODE arrived as the same sentence every other Stage got. So the
  # worker that most needs the real implementation was the one most likely to
  # anchor on whatever tree it woke up in — and anchoring on the wrong tree is how
  # a bug fix builds a parallel dead control beside the real one.
  #
  # The ref is the PARENT's branch (just resolved above for the prose block), not
  # this bug's own: the delivered code is the parent's. When the parent is
  # pre-merge these are literally the same branch — `lcars log` accumulates the fix
  # onto it — and when it is not, the parent's is still the tree the symptom was
  # reported against. Taken BEFORE `context_extra_block` for the same ordering
  # reason as cmd_validate.
  enter_mission_worktree "$parent_branch" research-grounding

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

  # S166 — make the branch pin STRUCTURAL, and do it BEFORE `extra` is assembled.
  # This is the S93 leak's home Stage: a Validator standing in a sibling Mission's
  # checkout is what decided a bug was "already fixed" and overrode a correct
  # grounding. Order matters — `context_extra_block` below resolves CONTEXT.md
  # relative to the repo we are standing in, and a path into the AMBIENT checkout
  # is both the wrong Mission's facts and (under a path-sandboxed CLI) unreadable
  # from here. Resolved after the move, it names this Mission's own copy.
  enter_mission_worktree "$(json_str "$STATE" branch)" validate

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
  # S147 DEFECT-3: price the tier that ACTUALLY RUNS, not the estimator's logical
  # tier. On copilot every stage resolves to opus, so a sonnet-tier estimate was
  # being billed at sonnet rates for an opus run — the band read low by design.
  # cli is derived from the pricing scope's first segment ("copilot.usage" →
  # copilot, "claude" → claude), which is the same engine the caller resolved.
  local usd_low=0 usd_high=0 k tier inr outr tlo thi
  local pcli="${scope%%.*}"
  for k in $stages; do
    tier="$(effective_tier_for_cli "$pcli" "$(json_scoped_str "$est" "models.$k")")"
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
      # S147 DEFECT-3: the multiplier must follow the tier that ACTUALLY runs.
      tier="$(effective_tier_for_cli copilot "$(json_scoped_str "$est" "models.$k")")"
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
  # Claude (default / unit "usd"). effective_tier_for_cli round-trips claude's
  # tiers unchanged, so this branch's numbers are byte-identical to before.
  local usd_low=0 usd_high=0 k tier inr outr tlo thi
  for k in $stages; do
    tier="$(effective_tier_for_cli claude "$(json_scoped_str "$est" "models.$k")")"
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

# The `usage --mission <id>` subcommand (session 112): sum the mission's
# usage.json (JSONL — one record per cold-worker spawn) per stage + a grand
# total. The read/parity surface S113 builds on. Pure (no LLM), tolerant of an
# absent or partial file. Reuses cost_compute NOTHING — it only aggregates the
# already-recorded ACTUALS (cost was computed at capture time).
cmd_usage() {
  local gitdir
  gitdir="$("$GIT_BIN" rev-parse --git-common-dir 2>/dev/null)" || gitdir=""
  if [ -n "$gitdir" ]; then
    case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
    LCARS_CFG="$gitdir/lcars/config.json"
    [ -n "${MISSION_ID:-}" ] && MISSION_DIR="$gitdir/lcars/missions/$MISSION_ID"
  fi
  local uf="${MISSION_DIR:-}/usage.json"
  printf 'USAGE mission=%s\n' "${MISSION_ID:-?}"
  if [ ! -f "$uf" ]; then
    printf 'TOTAL records=0 inputTokens=0 outputTokens=0 costUsd=0 premiumRequests=0\n'
    return 0
  fi
  "${LCARS_PYTHON_BIN:-python3}" - "$uf" <<'PY'
import json,sys
from collections import OrderedDict
stages=OrderedDict()
tot={'records':0,'inputTokens':0,'outputTokens':0,'costUsd':0.0,'premiumRequests':0}
def blank(): return {'records':0,'inputTokens':0,'outputTokens':0,'costUsd':0.0,'premiumRequests':0}
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    st=stages.setdefault(d.get('stage','?'), blank())
    st['records']+=1; tot['records']+=1
    for k in ('inputTokens','outputTokens','premiumRequests'):
        try: v=int(d.get(k,0) or 0)
        except Exception: v=0
        st[k]+=v; tot[k]+=v
    try: c=float(d.get('costUsd',0) or 0)
    except Exception: c=0.0
    st['costUsd']+=c; tot['costUsd']+=c
for s,st in stages.items():
    print('STAGE %s records=%d inputTokens=%d outputTokens=%d costUsd=%g premiumRequests=%d'%(
        s,st['records'],st['inputTokens'],st['outputTokens'],st['costUsd'],st['premiumRequests']))
print('TOTAL records=%d inputTokens=%d outputTokens=%d costUsd=%g premiumRequests=%d'%(
    tot['records'],tot['inputTokens'],tot['outputTokens'],tot['costUsd'],tot['premiumRequests']))
PY
}

# S113: sum a mission's usage.json (JSONL) into a COMPACT ACTUAL cost string in
# the mission's billing unit — usd → "$X.XX", copilot-legacy premiumRequests →
# "~N reqs" — matching the estimate pill's unit rules so EST and ACTUAL read in
# the SAME unit. A "· partial" suffix is appended when ANY stage's usage was
# `source":"unavailable"` (honest, never a silently-wrong total). Prints NOTHING
# when the file is absent or carries no records (so the no-usage CLI readout is
# byte-identical to before this round). Mirrors board.sum_usage / cmd_usage.
usage_actual_compact() { # usage-json-file → "$5.10" | "~42 reqs" | "$5.10 · partial" | ""
  local uf="$1"
  [ -f "$uf" ] || return 0
  "${LCARS_PYTHON_BIN:-python3}" - "$uf" <<'PY'
import json,sys
unit=None; usd=0.0; reqs=0; partial=False; n=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    n+=1
    try: usd+=float(d.get('costUsd',0) or 0)
    except Exception: pass
    try: reqs+=int(d.get('premiumRequests',0) or 0)
    except Exception: pass
    if d.get('source')=='unavailable': partial=True
    bu=d.get('billingUnit')
    if bu and unit is None: unit=bu
if not n: sys.exit(0)
s=('~%g reqs'%reqs) if unit=='premiumRequests' else ('$%.2f'%usd)
if partial: s+=' · partial'
sys.stdout.write(s)
PY
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

# The display name of the model a STAGE will actually run under the active CLI
# (S147 DEFECT-3). Every captain-facing model readout goes through here, so the
# estimator's logical tier can never again be shown as if it were the truth on an
# engine that remaps it. claude round-trips unchanged.
stage_tier_display() { # estimate-json cli stage-key → "Opus" | "Sonnet" | …
  tier_display "$(effective_tier_for_cli "$2" "$(json_scoped_str "$1" "models.$3")")"
}

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
# S147 round-2: takes the ACTIVE CLI so the note reports the tier that will
# really run. It printed the captain's LOGICAL tier, so on copilot an
# `all:sonnet` pin rendered "(override: Sonnet, whole run)" directly above a
# model mix of Opus/Opus — claiming a pin that alias_for_tier had already
# flattened. The note may say an override happened; it must not misreport what
# the override produced.
override_note() { # cli → "(override: …)" or empty
  local ov; ov="$(active_model_override)"
  [ -n "$ov" ] || return 0
  local scope="${ov%%:*}" tier="${ov#*:}" where
  tier="$(effective_tier_for_cli "${1:-claude}" "$tier")"
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
  local ovn; ovn="$(override_note "$cli")"
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
    printf '| %s | %s |\n' "$label" "$(stage_tier_display "$est" "$cli" "$k")"
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
  local ovn; ovn="$(override_note "$cli")"
  [ -n "$ovn" ] && printf '  Override: %s — model mix pinned by the captain (table below = estimator default)\n' "$ovn"
  # One-line model mix.
  printf '  Models:   research/validate=%s · plan/plan-review=%s · implement=%s · verify=%s\n' \
    "$(stage_tier_display "$est" "$cli" research)/$(stage_tier_display "$est" "$cli" validate)" \
    "$(stage_tier_display "$est" "$cli" plan)/$(stage_tier_display "$est" "$cli" planReview)" \
    "$(stage_tier_display "$est" "$cli" implement)" \
    "$(stage_tier_display "$est" "$cli" verify)"
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

  # S166 — structural pin, before `extra` (see cmd_validate for the ordering
  # reason). A Planner slicing against the wrong tree names files that do not
  # exist in the tree Implement will actually build in.
  enter_mission_worktree "$(json_str "$STATE" branch)" plan

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
  # S169: when one of those attachments is a MOCKUP, the contract that puts it
  # into the tickets themselves — the declaration, the criterion that must name
  # the drawing, and why the look is not deferred to Verify. EMPTY for a Mission
  # without a mockup, so every other Plan prompt is byte-identical.
  extra="$extra$(plan_mockup_contract_block)"
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

  # S166 — structural pin, before `extra` (see cmd_validate for the ordering
  # reason). The reviewer audits tickets AGAINST the code they claim to touch;
  # the wrong tree turns a correct ticket into a phantom-file objection, or waves
  # a real one through.
  enter_mission_worktree "$(json_str "$STATE" branch)" plan-review

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
# S133: ONE cold unified TDD worker per ticket — it writes the tests AND the
# code, in-tree, and the harness proves the work AFTERWARDS with the S132 gates
# (fail-on-parent / pass-on-tip + declared edits + the quality floor). A gate
# rejection bounces to a FRESH worker carrying the verdict; exhaustion parks
# awaiting-human.
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

  # --- S111 RUNNER PREFLIGHT (before ANY worker spend) -----------------------
  # Probe the configured testCommand in the ticket's target package. A runner
  # that cannot LAUNCH (a runner-less package — the S110 example-game 127 — or an
  # unprovisioned tree) makes the whole adversarial pair pointless: no Test-Writer
  # retry can conjure a runner. Park awaiting-human NOW, with the package named
  # and the runner's own output quoted, having spawned NOTHING. A second probe at
  # the repo root splits the diagnosis: package-without-runner vs nothing-runs.
  local pf_pkg pf_dir
  pf_pkg="$(ticket_target_package "$TICKET")"
  pf_dir="$REPO_ROOT${pf_pkg:+/$pf_pkg}"
  # S133 SELF-HEAL: before escalating a dead runner to a human, re-apply the
  # captain's OWN declared worktreeSetupCommand ONCE and re-probe — a silent /
  # transient provisioning miss then clears itself instead of stranding a human
  # at an un-answerable env gate. Escalate ONLY if the runner still cannot launch.
  if ! preflight_runner_or_heal "$pf_dir"; then
    # S133 (span-packages false negative, caught live on bug lcars-20260713-003):
    # a ticket whose relevant files span MORE THAN ONE package has NO single target
    # package, so ticket_target_package returns "" and the preflight probed the REPO
    # ROOT. In a non-hoisted monorepo (pnpm keeps vitest in each package's
    # node_modules, NOT the root) the root has no runner → a FALSE "cannot test",
    # even though the ticket's test WILL be placed and run in a real package that
    # can. So: when the target package is empty (root-probed) AND some package can
    # run tests, DON'T park — proceed and let the red gate judge in the package
    # where the test lands. Only when NOTHING can run tests anywhere do we escalate.
    if [ -z "$pf_pkg" ] && repo_tests_elsewhere ""; then
      emit_event preflight_spans_packages implement \
        "$TICKET spans packages (no single target package) and the repo root has no hoisted runner, but a package can run tests — proceeding; the red gate judges where the test lands" \
        "ticket=$TICKET"
    else
    local pf_out="$PREFLIGHT_OUT" pf_root_alive=0
    if [ -n "$pf_pkg" ] && repo_tests_elsewhere "$pf_pkg"; then
      pf_root_alive=1
    fi
    # S111 3′: a RUNNER-LESS PACKAGE in an otherwise-working repo is the case a
    # DECLARED TEST SETUP can self-heal — INVITE the implementer (evidence rides
    # the prompt) instead of parking, unless a setup was already tried for this
    # mission (then the human decides) or the captain disabled the mechanism.
    if [ "$pf_root_alive" = 1 ] \
       && [ ! -f "$MISSION_DIR/test-setup-applied.json" ] \
       && [ "${LCARS_DECLARED_SETUP:-1}" != "0" ]; then
      export LCARS_SETUP_EVIDENCE="package '$pf_pkg' cannot run tests (the repo root can). Command probed: $(resolve_test_cmd) (from: $pf_dir). Runner said:
$(printf '%s' "$pf_out" | tail -10)"
      emit_event test_setup_invited implement \
        "package '$pf_pkg' has no working test runner — inviting the implementer to declare the missing test setup (evidence-gated)" \
        "ticket=$TICKET"
    else
      local pf_diag
      if [ "$pf_root_alive" = 1 ]; then
        pf_diag="package '$pf_pkg' has no working test runner (the repo root can run tests; that package cannot), and a declared test setup was already tried for this mission without curing it. Add a test runner to '$pf_pkg' yourself, set a package-specific test command, or retarget the mission."
      else
        pf_diag="the test runner cannot launch anywhere in this checkout and no other package in this repo declares a known test runner — the environment is not provisioned (are dependencies installed? is worktreeSetupCommand set?). A declared setup cannot fix repo-wide provisioning."
      fi
      impl_park_env_cannot_test "$TICKET" \
"Ticket $TICKET cannot start: $pf_diag
Command probed: $(resolve_test_cmd) (from: $pf_dir)
Runner said:
$(printf '%s' "$pf_out" | tail -10)"
    fi
    fi
  fi

  # NOTE: `attempt` in the ticket_attempt events below is the CUMULATIVE
  # worker-DISPATCH count for this ticket ACROSS invocations — one index per real
  # spawn_worker dispatch, derived from events.jsonl so it never repeats or
  # restarts when a fresh process re-enters. DISTINCT from the worker's own
  # internal iteration count that lands in result.json.attempts (S133:
  # informational, uncapped-but-reported).
  # The durable repo context source (shared declarative facts, by PATH only).
  # The captain's durable image attachments (S92) ride the same artifact-paths
  # list (ABSOLUTE paths) so the worker can view them; empty when none exist.
  local cblock; cblock="$(context_extra_block)$(attachments_extra_block)"
  # S111 (the 002 wrong-tree lesson): when this build runs in an ISOLATED
  # worktree, PIN both workers to it by absolute path. Input artifacts under the
  # shared .git/lcars/ may mention the main clone root; a worker following those
  # paths lands its edits in the WRONG tree. Empty for non-worktree builds.
  local wtblock=""
  [ -n "${LCARS_TICKET_WORKTREE:-}" ] && wtblock="

## Your repository working tree — THE ONLY TREE YOU MAY TOUCH
$LCARS_TICKET_WORKTREE
This exact absolute path is your cwd and your ONLY copy of the repository: read
the code from here, and (if your role writes) create/edit files ONLY under this
path. NEVER follow a path into any OTHER checkout of this repository (e.g. the
main clone root) — if an input artifact names one, translate that path into this
working tree first. Files written anywhere else are LOST to this ticket."
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

  # Session 22 (re-addressed S133): the inlined ticket spec — THIS ticket's
  # title + description + acceptanceCriteria TEXT, extracted from
  # approved-plan.json so the cold worker SEES what to build + test instead of
  # having to find it in the plan (the path-only handoff let a worker ground on
  # the wrong artifact and build the wrong feature). Resolved ONCE; appended
  # under "## Your ticket" in the unified worker's prompt.
  # CLI-AGNOSTIC: shared assembly, no per-CLI branch. Empty on a ticket missing
  # from the plan, so the bare id line below still carries the handoff.
  local tspecblock; tspecblock="$(ticket_spec_block "$MISSION_DIR/approved-plan.json" "$TICKET")"
  [ -n "$tspecblock" ] && tspecblock="
$tspecblock"

  # --- S133: THE UNIFIED TDD WORKER + POST-HOC PROOF GATES --------------------
  # ONE cold worker owns the ticket end-to-end — it writes tests AND code, in any
  # order, authored IN-TREE at the repo's own convention — and proof moves AFTER
  # implementation. The PARENT COMMIT is the snapshot (git itself): the S132
  # gates verify result v2 → declared-edits → quality floor → flip-flop
  # (green-on-tip + red-on-parent), then the EXISTING commit_ticket + post-commit
  # + full-suite flow runs unchanged. Any gate FAIL/INCONCLUSIVE writes
  # tickets/<id>/gate-signal.txt (gate name + verdict + runner tail — the
  # red-gate-signal idiom) and re-spawns a FRESH worker carrying that signal;
  # cap MAX_WORKER_TRIES total sessions; exhaustion PARKS awaiting-human with
  # the last verdict quoted — NEVER a die. `lcars respond` + re-run resumes
  # (answers.json rides the next session's prompt).
  local parent_sha
  parent_sha="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" \
    || die "no parent commit — the repo has no HEAD to prove fail-on-parent against (commit something first)."

  local tdir; tdir="$(ticket_dir "$TICKET")"
  local sigfile="$tdir/gate-signal.txt"
  local sessions=0 empty_tries=0 prior_empty="" last_verdict="" awtry=0
  local odir=""

  # RESUME after a park was answered: the captain's recorded note is how to get
  # this ticket unstuck. Feed it so the worker acts on it rather than re-hitting
  # the same wall.
  local ansblock=""
  [ -f "$MISSION_DIR/answers.json" ] && ansblock="
- $MISSION_DIR/answers.json   (the captain's answer resolving the prior block on this ticket — treat it as DECIDED)"
  # SELF-HEAL feedback (BUG-029): when the full-suite gate found this ticket's
  # change REGRESSED an earlier ticket's test, cmd_impl_advance re-runs this
  # ticket with $LCARS_SELFHEAL_FEEDBACK carrying the harness-authored reconcile
  # instruction. SIGNAL ONLY — same declarative channel as the gate signal.
  local healblock=""
  if [ -n "${LCARS_SELFHEAL_FEEDBACK:-}" ]; then
    healblock="

## FULL-SUITE RECONCILE FEEDBACK — your change regressed an earlier ticket (read this first)
A previous build of this ticket passed its OWN tests but, integrated with the
rest of the branch, it REGRESSED an earlier ticket's test. Reconcile your change
with the rest of the branch so EVERY suite (yours AND the regressed one) passes
again. Do NOT weaken the regressed test to get there; if adapting ANY existing
test is genuinely required by this ticket's stated change, declare it in
result.json testEdits with the reason. The harness's verdict (the regressed
suite(s) + the command run):
$LCARS_SELFHEAL_FEEDBACK"
  fi

  # Reject THIS session with a durable gate signal; the loop re-spawns fresh.
  # A bounced session's result.json must never linger where ticket_green reads.
  _tdd_reject() { # gate-name  verdict  detail
    last_verdict="$1 ($2)"
    {
      printf 'GATE: %s — verdict=%s\n' "$1" "$2"
      printf '%s\n' "$3"
    } >"$sigfile"
    emit_event ticket_gate_bounce implement \
      "ticket $TICKET bounced by the $1 gate ($2) — session $awtry; re-spawning a fresh worker with the verdict" \
      "ticket=$TICKET" "gate=$1" "attempt=$awtry"
    rm -f "$tdir/result.json"
    rm -rf "$odir"
  }

  while [ "$sessions" -lt "$MAX_WORKER_TRIES" ]; do
    sessions=$((sessions + 1))
    # attempt = 1 + (existing ticket_attempt lines for THIS ticket, phase=tdd) —
    # the CUMULATIVE worker-dispatch count across invocations, one unique index
    # per real spawn_worker dispatch (same idiom the old per-phase loops used).
    awtry=$(( $(event_count ticket_attempt "\"ticket\":\"$TICKET\".*\"phase\":\"tdd\"") + 1 ))
    emit_event ticket_attempt implement "tdd session $awtry for $TICKET" \
      "ticket=$TICKET" "phase=tdd" "attempt=$awtry"

    # GATE FEEDBACK — a prior session's gate verdict + runner tail rides the
    # fresh worker's prompt (the red-gate-signal idiom, generalized to every
    # gate). SIGNAL ONLY: the harness's own verdict + runner output, never the
    # prior worker's code or reasoning.
    local retryblock=""
    if [ -f "$sigfile" ]; then
      retryblock="

## GATE FEEDBACK — a PREVIOUS session of this ticket was REJECTED (read this first)
The harness verified that session's work mechanically and rejected it. This is
the gate's verdict and the runner's own output — the ONLY thing carried over
(you do not see the prior session's code or reasoning). Fix THIS:
$(cat "$sigfile")"
    fi

    odir="$(mktemp -d)"
    # Harness owns directory scaffolding: pre-create the setup/ scratch subdir so
    # a declared-setup manifest's files land without needing a mkdir (S111 3′;
    # CLI-neutral — a worker that emits no setup is unaffected).
    mkdir -p "$odir/setup"

    # S111 3′: the declared-setup INVITATION — appended ONLY when the preflight
    # observed the gap and exported the evidence. Re-addressed to the unified
    # worker: it authors tests IN-TREE itself now (no harness relocation), so the
    # S131 placement contract states WHERE those tests must live — the repo's
    # detected convention — so a declared runner config collects them (the
    # include-vs-placement trap, caught live 2026-07-09).
    local setupblock=""
    if [ -n "${LCARS_SETUP_EVIDENCE:-}" ]; then
      local sb_src sb_conv sb_example sb_for
      sb_src="$(ticket_target_src "$TICKET")"
      sb_conv="$(detect_test_convention "$REPO_ROOT" "$sb_src")"
      sb_example="$(test_path_for "$sb_conv" "${sb_src:-${pf_pkg:+$pf_pkg/}src/index.ts}")"
      # NB: computed OUTSIDE the block below — macOS bash 3.2 mis-parses an
      # apostrophe inside a \${var:-default} expansion in a double-quoted string.
      sb_for="$sb_src"
      [ -n "$sb_for" ] || sb_for="this ticket's module"
      setupblock="

## DECLARED TEST SETUP — the target package cannot run tests; you may provision it
The harness probed this ticket's target package and the test runner CANNOT
launch there. This is the harness's own observation (the evidence):
$LCARS_SETUP_EVIDENCE
You are INVITED to declare the missing test infrastructure ALONGSIDE your work,
and the HARNESS will apply and verify it:
- Write any NEW config/setup files into the \`setup/\` subdir of your scratch
  output directory, at their PACKAGE-RELATIVE paths — e.g. \`setup/vitest.config.ts\`.
  ADD-only: never a file that already exists, never anything under \`src/\`.
  Keep it minimal (at most 4 small files).
- PLACEMENT CONTRACT — where your tests must LIVE to be collected: author your
  tests IN THE REPO TREE at its own test convention — detected here: $sb_conv —
  e.g. a test for \`$sb_for\` lives in-tree at \`$sb_example\`. Any
  runner config you declare MUST collect tests from that in-tree location.
  Safest: do NOT narrow \`include\` at all (vitest's default include already
  matches both co-located src/**/*.test.* and tests/**); an \`include\` that
  misses your tests' real location collects ZERO tests at the gate and bounces
  your session.
- Create \`test-setup.json\` in the scratch output directory root (NOT inside
  setup/):
  {\"package\": \"<the package dir named in the evidence>\",
   \"gap\": \"<one line: what is missing>\",
   \"installCommand\": \"<a plain package-manager command run inside that package, e.g. pnpm add -D vitest@^1.6>\"}
  Match the workspace's existing runner + version (look at the sibling
  packages' package.json) — never introduce a different framework than the
  repo already uses elsewhere.
- Then do the ticket exactly as normal. The harness applies your setup,
  re-probes the runner, and your tests must still prove the flip-flop (green on
  your tree, red on the parent) — a setup that fakes green is rejected."
    fi

    spawn_worker implement-tdd "$STAGES_DIR/implement-tdd.md" repo-write "$odir" \
"## Read these artifacts (your ONLY inputs)
- $MISSION_DIR/approved-plan.json$adrblock$navblock$cblock$wtblock$setupblock$ansblock$healblock

## Your ticket
$TICKET$tspecblock$retryblock" "${prior_empty:-}"

    # S98: EMPTY-WORKER branch — a worker that produced NOTHING (no file AND no
    # stdout/stderr) is the transient-CLI signal, NOT a gate rejection. It does
    # not consume a proof session: bounded-retry with the file-first re-prompt,
    # then escalate DISTINCTLY after the short cap (budget unchanged from the
    # standoff era).
    if worker_produced_nothing "$odir"; then
      sessions=$((sessions - 1))   # a transient-CLI blank never burns a proof session
      empty_tries=$((empty_tries + 1))
      emit_event ticket_worker_empty_output implement \
        "tdd worker produced no output for $TICKET (attempt $awtry)" \
        "ticket=$TICKET" "phase=tdd" "attempt=$awtry" "category=empty-worker-output"
      if [ "$empty_tries" -ge "$MAX_EMPTY_WORKER_TRIES" ]; then
        local ew_phrase; ew_phrase="$(impl_failure_category_phrase empty-worker-output)"
        emit_event ticket_implementer_failed implement \
          "ticket $TICKET stopped: $ew_phrase" \
          "ticket=$TICKET" "phase=tdd" "category=empty-worker-output" "attempts=$empty_tries"
        if [ -n "${MISSION_DIR:-}" ]; then
          printf '%s\tticket=%s\t%s: %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" "$TICKET" \
            "empty-worker-output" "$ew_phrase" \
            >>"$MISSION_DIR/implement-failure.log" 2>/dev/null || :
        fi
        rm -rf "$odir"
        die "the TDD worker produced no output $empty_tries times for $TICKET — likely a transient CLI failure, not a code problem — Stage stopped."
      fi
      prior_empty=1
      rm -rf "$odir"
      continue
    fi
    prior_empty=""

    # S111 3′: apply a declared setup manifest when the worker emitted one AND
    # the evidence gate is open (no evidence → ignored; attempt 1 always naked).
    # An applied-but-still-dead runner is genuinely incurable → park (env idiom).
    if [ -f "$odir/test-setup.json" ]; then
      if [ -n "${LCARS_SETUP_EVIDENCE:-}" ]; then
        if apply_declared_setup "$odir/test-setup.json" "$odir/setup" "$pf_pkg"; then
          [ -n "$SETUP_NOTE" ] && printf '  ⚠ declared setup applied with a note: %s\n' "$SETUP_NOTE" >&2
          if runner_preflight_env_failure "$pf_dir"; then
            rm -rf "$odir"
            impl_park_env_cannot_test "$TICKET" \
"Ticket $TICKET is blocked: the declared test setup was APPLIED (files + install) but the runner STILL cannot launch in ${pf_pkg:-<root>}. Setup note: ${SETUP_NOTE:-none}
Runner said after the setup:
$(printf '%s' "$PREFLIGHT_OUT" | tail -10)"
          fi
          printf '  ✓ declared setup applied — the runner now launches in %s (the proof gates demand the honest flip-flop next)\n' "${pf_pkg:-<root>}" >&2
        else
          printf '  ⚠ declared setup REJECTED: %s — continuing without it\n' "$SETUP_NOTE" >&2
          emit_event test_setup_rejected implement \
            "declared setup rejected: $SETUP_NOTE" "ticket=$TICKET"
        fi
      else
        printf '  ⚠ a test-setup.json was provided WITHOUT an observed infra gap — ignored (setup is invited only after the harness itself hits the failure; attempt 1 always runs naked)\n' >&2
      fi
    fi

    # --- THE PROOF GATES (S132), in order ------------------------------------
    local rf="$odir/result.json"
    if [ ! -f "$rf" ]; then
      _tdd_reject result missing \
"the worker produced no result.json in its scratch output directory — the harness reads ONLY that file. Worker output tail:
$(cat "$odir/.worker.out" "$odir/.worker.err" 2>/dev/null | tail -10)"
      continue
    fi
    # The gates read tickets/<id>/result.json — persist it BEFORE gating (it is
    # removed again on any rejection so a bounced session never reads as green).
    mkdir -p "$tdir"; cp "$rf" "$tdir/result.json"

    local gerr=""
    if ! gerr="$(proof_validate_result "$tdir/result.json" "$TICKET" 2>&1)"; then
      _tdd_reject result-v2 FAIL "$gerr"; continue
    fi
    if [ "$(json_raw "$tdir/result.json" passed)" = "false" ]; then
      _tdd_reject worker-report not-green \
"the worker itself reports the ticket is NOT green after $(json_raw "$tdir/result.json" attempts) iteration(s): $(json_str "$tdir/result.json" summary)"
      continue
    fi
    if ! gerr="$(declared_edits_guard "$TICKET" "$parent_sha" "$REPO_ROOT" 2>&1)"; then
      _tdd_reject declared-edits FAIL "$gerr"; continue
    fi
    if ! gerr="$(proof_quality_floor "$TICKET" "$parent_sha" "$REPO_ROOT" 2>&1)"; then
      _tdd_reject quality-floor FAIL "$gerr"; continue
    fi
    # flip-flop: rc 0 pass/skip, 1 fail, 2 inconclusive (never a pass). Runs in
    # a subshell (output captured for the signal); its events + flip-flop.json
    # land on disk either way, and the json carries both legs' rc + tails.
    local ffrc=0 ffout=""
    ffout="$(flip_flop_gate "$TICKET" "$parent_sha" "$REPO_ROOT" 2>&1)" || ffrc=$?
    [ -n "$ffout" ] && printf '%s\n' "$ffout"
    if [ "$ffrc" -ne 0 ]; then
      local ffv=FAIL; [ "$ffrc" = 2 ] && ffv=INCONCLUSIVE
      _tdd_reject flip-flop "$ffv" \
"$ffout
$(cat "$tdir/flip-flop.json" 2>/dev/null)"
      continue
    fi

    # --- ALL GATES PASS — persist through the EXISTING flow ------------------
    # Record the proof-time test hashes (the declared-edits-aware drift baseline
    # for post-commit / pre-merge), then commit + post-commit-verify + green +
    # issue close via impl-save-result, byte-compatible with the old flow.
    proof_snapshot_tests "$TICKET" "$REPO_ROOT"
    local src_rc=0 srout=""
    srout="$(LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" bash "$SELF" impl-save-result \
      --mission "$MISSION_ID" --ticket "$TICKET" --result "$rf" 2>&1)" || src_rc=$?
    [ -n "$srout" ] && printf '%s\n' "$srout"
    if [ "$src_rc" -eq 0 ]; then
      rm -f "$sigfile"
      rm -rf "$odir"
      isolated_line "implement($TICKET)" 1
      exit 0
    fi
    # The committed state did not verify (post-commit red / env / undeclared
    # drift). Bounce with the save flow's own verdict as the signal.
    _tdd_reject post-commit FAIL "$(printf '%s' "$srout" | tail -20)"
    continue
  done

  # --- EXHAUSTION: park awaiting-human, NEVER die ----------------------------
  # The same gate shape as validate-pause / the old 5-attempt flag: pending.json
  # (BUG-027 structured fields), awaitingHuman + label overlay, ticket_flagged.
  # `lcars respond` records the answer; a re-run resumes with it (answers.json).
  local lastsig=""; [ -f "$sigfile" ] && lastsig="$(cat "$sigfile")"
  local q; q="$(mktemp)"
  printf 'Ticket %s was rejected by the proof gates in %s consecutive TDD session(s). Last gate verdict:\n%s\n' \
    "$TICKET" "$sessions" "${lastsig:-no gate signal captured}" >"$q"
  LCARS_PENDING_HUMAN_SUMMARY="Ticket $TICKET could not prove its work after $sessions session(s) — the last gate verdict is quoted below. Reply with direction (what to fix, rescope, or drop the ticket) and re-run." \
  LCARS_PENDING_ESCALATION_TYPE="cap" \
  LCARS_PENDING_TECHNICAL_DETAIL="${lastsig:-no gate signal captured}" \
    write_pending "$q" "implement"
  rm -f "$q"
  state_set_raw awaitingHuman true
  state_set_str pendingQuestion "Ticket $TICKET failed its proof gates after $sessions session(s) — needs a human."
  gh_relabel "lcars:awaiting-human" ""
  emit_event ticket_flagged implement \
    "ticket $TICKET flagged after $sessions TDD session(s) — last gate verdict: ${last_verdict:-unknown}" \
    "ticket=$TICKET" "attempts=$sessions"
  echo "IMPLEMENT: ticket flagged — $TICKET"
  echo "  $TICKET was bounced by the proof gates $sessions time(s) (the $MAX_WORKER_TRIES-session cap)."
  echo "  Last gate verdict: ${last_verdict:-unknown}"
  echo "  Stage: implement (awaiting-human). Resolve with \`lcars respond $MISSION_ID\`."
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === Test reconciliation: RETIRED (S133) ===================================
# BUG-058's reconcile_tests pre-step (a cold worker adapting the PARENT
# mission's locked tests a logged bug's change invalidates) is DELETED with the
# standoff: the unified TDD worker may itself adapt a contradictory parent test
# — the immutable-tests lock no longer forbids it — and MUST declare each such
# edit in result.json testEdits with a reason (enforced by declared_edits_guard,
# recorded to test-edits.json, audited by the pre-merge drift check).

# === Stage driver: Implement (the whole stage) =============================
# The token-free wave loop. It processes the waves in order and, within a wave,
# builds every pending ticket through `implement-ticket` (the cold unified TDD
# worker + proof gates), then advances to Verify once every ticket is green. It
# composes the already-tested impl-* subcommands and adds NO new Stage logic —
# it only sequences them, the same way the auto-advance driver sequences Stages.
# A ticket that flags the human (the session-cap park → awaiting-human) stops
# the loop at the gate; a hard worker failure stops the Stage non-zero.
cmd_implement() {
  locate_mission "$MISSION_ID"
  require_stage implement
  require_worker

  # (S133: the BUG-058 reconcile_tests pre-step for logged bugs is retired — the
  # unified TDD worker adapts a contradictory parent test itself, DECLARED in
  # result.json testEdits and enforced by declared_edits_guard.)

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
        rm -f "$(ticket_dir "$t")/.build-rc" "$(ticket_dir "$t")/.commit-sha" "$(ticket_dir "$t")/.commit-base" 2>/dev/null
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
        # (S133: the separate locked-test commit replay is retired — the ticket's
        # tests ride in its ONE commit below.)
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
  local wt="$1" cmd="" rc=0
  if [ -n "${LCARS_WORKTREE_SETUP_CMD:-}" ]; then
    cmd="$LCARS_WORKTREE_SETUP_CMD"
  elif [ -f "$LCARS_CFG" ]; then
    cmd="$(json_str "$LCARS_CFG" worktreeSetupCommand)"
  fi
  case "$cmd" in ''|null) cmd="" ;; esac
  if [ -n "$cmd" ]; then
    # Run ONCE with the worktree as CWD; capture combined output for the breadcrumb.
    local out; out="$( cd "$wt" && bash -c "$cmd" 2>&1 )" || rc=$?
    if [ "$rc" -ne 0 ]; then
      emit_event worktree_provision_failed implement \
        "worktreeSetupCommand exited $rc in $wt — provisioning is best-effort, the gate continues" \
        "rc=$rc"
    fi
  fi
  # S111 3′: re-apply this mission's declared-setup install (when one was
  # applied) so post-commit / full-suite / reconcile gates judge the SAME
  # provisioned env the red gate did. Best-effort, after the base provisioning.
  setup_reapply_in_worktree "$wt" || :
  return "$rc"
}

# --- per-ticket worktree lifecycle (Session 37) -----------------------------
# Create a detached worktree at the mission-branch tip for ONE ticket's build, so
# concurrent tickets never collide on the shared working tree. The branch itself
# stays checked out in the main tree; the worktree is DETACHED at its tip.
make_ticket_worktree() { # base-dir  branch  ticket → echoes the worktree path (empty ⇒ fall back to in-tree)
  local base="$1" branch="$2" t="$3"
  # No branch ref (a branch-less / local-only mission, or an unborn HEAD) ⇒ no
  # worktree; the caller falls back to the original in-tree path. Echo nothing.
  # This is the ONLY quiet fallback left: with a REAL branch, every failure below
  # is LOUD (S111). The old `|| return 0` on a failed `worktree add` silently
  # dropped the whole build into the SHARED clone-root checkout — the Implementer
  # then edited whatever branch happened to be checked out there (the S110 002
  # wrong-tree failure; a stale registration from a manual reset was enough to
  # trigger it).
  [ -n "$branch" ] && "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch" || return 0
  local wt="$base/$t"
  if ! mkdir -p "$base" 2>/dev/null; then
    printf 'lcars run: cannot create the worktree base dir %s (path blocked by a file?) — REFUSING the in-tree fallback: a mission with a real branch must build in an isolated worktree, never the shared checkout.\n' "$base" >&2
    return 1
  fi
  "$GIT_BIN" worktree remove --force "$wt" >/dev/null 2>&1 || :
  rm -rf "$wt"
  local add_err=""
  if ! add_err="$("$GIT_BIN" worktree add -q --detach "$wt" "$branch" 2>&1 >/dev/null)"; then
    # SELF-HEAL: the dominant cause is a STALE registration — a prior worktree dir
    # deleted without `git worktree prune` (manual resets do this). Prune + retry
    # once; only a second failure is terminal, and it is LOUD.
    "$GIT_BIN" worktree prune >/dev/null 2>&1 || :
    rm -rf "$wt"
    if ! add_err="$("$GIT_BIN" worktree add -q --detach "$wt" "$branch" 2>&1 >/dev/null)"; then
      rm -rf "$wt"
      printf 'lcars run: could not cut the per-ticket worktree at %s for branch %s (git: %s) — REFUSING the in-tree fallback: building in the shared checkout risks landing edits on the wrong branch. Free or prune stale worktrees (`git worktree list`, `git worktree prune`) and re-run.\n' \
        "$wt" "$branch" "$(printf '%s' "$add_err" | tr '\n' ' ')" >&2
      return 1
    fi
  fi
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

# The atomic critical section — runs ONLY while the replay mutex is held.
# S111 ROOT-TREE SOVEREIGNTY: the commit lands via an EPHEMERAL "landing"
# worktree ATTACHED to the mission branch — the captain's main checkout is
# NEVER checked out, detached, or dirtied by a mission again (the old path
# `git checkout $branch` + `cherry-pick` in $REPO_ROOT is what left clones
# stranded on mission branches and fought the captain's own branch switching).
# The landing worktree is created fresh and removed per replay, all inside the
# repo-global mutex, so: (a) a sibling mission can never contend for it, (b) a
# failed pick's residue dies with the tree — no untracked-cleanup needed, and
# (c) the reconcile's own ATTACHED worktree cut (Verify stage) never finds the
# branch held, because nothing holds it between replays.
_replay_ticket_commit_locked() { # branch  sha  ticket
  local branch="$1" sha="$2" t="$3"
  "$GIT_BIN" show-ref --verify --quiet "refs/heads/$branch" \
    || { REPLAY_FAIL_REASON="branch $branch does not exist — nothing to land on"; return 1; }
  local land="$MISSION_DIR/landing"
  _landing_cleanup() {
    "$GIT_BIN" worktree remove --force "$land" >/dev/null 2>&1 || rm -rf "$land"
    "$GIT_BIN" worktree prune >/dev/null 2>&1 || :
  }
  _landing_cleanup
  local add_err=""
  if ! add_err="$("$GIT_BIN" worktree add -q "$land" "$branch" 2>&1 >/dev/null)"; then
    "$GIT_BIN" worktree prune >/dev/null 2>&1 || :
    rm -rf "$land"
    if ! add_err="$("$GIT_BIN" worktree add -q "$land" "$branch" 2>&1 >/dev/null)"; then
      # An ATTACHED add fails when something ELSE holds the branch. Under
      # sovereignty LCARS itself never holds it between replays — so name the
      # holder: usually the CAPTAIN's own checkout sitting on the mission branch.
      local held_wt
      held_wt="$( cd "$REPO_ROOT" && "$GIT_BIN" worktree list --porcelain 2>/dev/null \
        | awk -v b="branch refs/heads/$branch" '
            /^worktree /{p=substr($0,10)}
            $0==b{print p; exit}' )"
      if [ -n "$held_wt" ]; then
        REPLAY_FAIL_REASON="branch $branch is checked out at $held_wt (likely your own checkout) — git will not let the fix land while that tree holds the branch. The ticket's fix is built and green; switch that checkout to another branch (or \`git worktree remove\` a stale tree) and re-run implement. LCARS lands mission commits via its own worktree and never touches your checkout."
      else
        REPLAY_FAIL_REASON="could not cut the landing worktree for branch $branch${add_err:+; git: $(printf '%s' "$add_err" | tr '\n' ' ')}"
      fi
      return 1
    fi
  fi
  # Capture the cherry-pick's own STDERR (the git error) and, while the conflict
  # state still exists (BEFORE --abort wipes it), the list of conflicted paths —
  # so a genuine replay failure records WHY instead of discarding it (BUG-051).
  local cp_err
  cp_err="$( cd "$land" && "$GIT_BIN" cherry-pick --allow-empty "$sha" 2>&1 >/dev/null )" || {
    local cp_conflicts
    cp_conflicts="$( cd "$land" && "$GIT_BIN" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ' )"
    REPLAY_FAIL_REASON="cherry-pick of $sha failed${cp_conflicts:+; conflicted paths: ${cp_conflicts% }}${cp_err:+; git: $(printf '%s' "$cp_err" | tr '\n' ' ')}"
    ( cd "$land" && "$GIT_BIN" cherry-pick --abort >/dev/null 2>&1 ) || :
    _landing_cleanup
    return 1
  }
  _landing_cleanup
  return 0
}

# Rebuild ONE ticket serially when its concurrent (frozen-base) commit could not
# cherry-pick — the same-file conflict fix. S133: the whole unified TDD worker
# re-runs (no stale-contract reuse — the S132 gates re-prove on the new tip), and
# it re-runs inside a FRESH worktree that make_ticket_worktree cuts off the CURRENT
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
  rm -f "$(ticket_dir "$t")/.build-rc" "$(ticket_dir "$t")/.commit-sha" "$(ticket_dir "$t")/.commit-base" 2>/dev/null
  local irc=0
  LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN" \
  LCARS_TICKET_WT_BASE="$base" LCARS_TICKET_BRANCH="$branch" \
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

# WHICH TREE DID THAT STAGE READ? (S166) The Stage answers that on its own stdout,
# in a full sentence — and the driver captures its stdout and re-emits only the one
# synthesized line below, so the captain on the DOCUMENTED path (`lcars run`) was
# the one person never told. Lift the branch@sha out and hang it on the summary
# line as a marker: the same move `⊘ isolated` already makes on `isolated_line`'s
# sentence, so the drive readout stays one tidy line per Stage instead of a
# firehose of Stage output.
#
# NO SENTENCE ⇒ NO MARKER. A Mission with no branch of its own cuts no tree and
# says so; synthesizing a plausible-looking branch@sha for it would be the exact
# lie S159 was about — a marker asserting what it never measured. Same rule if the
# sentence is ever reworded past recognition: say nothing rather than guess.
drive_tree_marker() { # stage-output → "   ⌂ <branch> @ <sha>" | ""
  local line q="'" b s
  line="$(printf '%s' "$1" | grep -m1 '⌂ mission tree' 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  b="${line#*reads $q}"; b="${b%%$q*}"
  s="${line#*$q @ }";    s="${s%% *}"
  [ -n "$b" ] && [ -n "$s" ] && printf '   ⌂ %s @ %s' "$b" "$s"
  return 0
}

# --- one summary line for a Stage that just ran ------------------------------
drive_line() { # stage  stage-output  ok|paused
  # The tree is worth naming on BOTH outcomes: an escalated Stage read a tree too,
  # and "which code was it looking at when it asked me this?" is the first thing
  # the answer depends on.
  local tree; tree="$(drive_tree_marker "$2")"
  if [ "$3" = paused ]; then
    printf '%-12s ⏸  escalated — awaiting your answer%s' "$1" "$tree"
    return
  fi
  local detail iso=""
  detail="$(drive_detail "$1" "$2")"
  # ANCHOR ON THE MARKER, NEVER THE WORD. The only thing that proves a Stage ran
  # cold is the line `isolated_line` prints — `⊘ isolated — <stage> ran in N cold
  # worker(s) via <bin>` — and it prints it only after a worker really spawned.
  # The bare word "isolated" is reachable from PROSE: S166's ⌂ tree sentence says
  # "in an isolated worktree", and Schedule's wave reason says "isolated into a
  # wave of its own". Matching the word let either sentence certify a Stage all
  # by itself, which is precisely the masquerade `require_worker` refuses to
  # allow. Match the glyph+word pair, so the marker stays evidence.
  printf '%s' "$2" | grep -q '⊘ isolated' && iso="   ⊘ isolated"
  printf '%-12s ✓  %s%s%s' "$1" "${detail:-advanced}" "$iso" "$tree"
}

drive_print_summary() { # accumulated-lines
  [ -n "$1" ] && printf '%s\n' "$1"
  printf '%s\n' "$SEP"
}

# === S159 — the DRIVE-TIME base re-check ====================================
# Filing and starting are separate moments. S158 brings the base up to date when
# the Mission is FILED; a Mission parked overnight — or filed now and driven
# tomorrow — still enters Research against whatever the base was at filing time.
# DX-Scorecard's lcars-20260730-001 was filed at 16:00 and driven later, and
# Research truthfully reported that a file "does not exist" because in THAT tree
# it did not.
#
# So the drive re-asks the question ONCE, at the top, before the stage loop
# spawns anything. The DOCTRINE IS S158'S, UNCHANGED: it never blocks the drive
# (every path returns 0), never writes into a dirty tree, never resets/forces/
# stashes/checks out, and always says what it did. There is ONE implementation of
# that judgement — `ensure_base_current` in lcars-common.sh — and this consumes
# it; nothing about freshness is re-decided here.
#
# It writes back the REFRESHED `state.json.baseFreshness` record (same shape, new
# verdict + checkedAt) and — only when the drive really did begin against a base
# that was BEHIND — one `base_stale` event on the Mission timeline, so the board's
# activity feed and `lcars status` can show it.
#
# AND IT MOVES THE MISSION'S OWN BRANCH (captain ruling 2026-07-31), because the
# base moving is not what a Stage reads. See `lcars_base_advance_mission_branch`
# in lcars-common.sh for the three lanes and the losslessness rule.

# Load the shared guard LAZILY, and only for the driver. run.sh is re-entered as
# a subprocess for every Stage and every ticket; sourcing a second library into
# all of them to serve one caller is blast radius for nothing. Best-effort: a
# missing lib degrades the drive to exactly its pre-S159 behaviour.
drive_load_base_lib() {
  command -v ensure_base_current >/dev/null 2>&1 && return 0
  local lib="${LCARS_COMMON_LIB:-$SKILL_DIR/../lcars-init/lcars-common.sh}"
  [ -f "$lib" ] || return 1
  # shellcheck source=../lcars-init/lcars-common.sh
  . "$lib" || return 1
  command -v ensure_base_current >/dev/null 2>&1
}

# Persist the refreshed record. state.json's editors are LINE-oriented, and
# `lcars_base_state_line` emits the whole record on ONE line for exactly that
# reason (S158), so the update is: drop the old line, insert the new one after
# the opening brace. Nothing else in the file is touched.
drive_persist_base_freshness() { # mission-branch
  local line
  line="$(lcars_base_state_line "${1:-}")" || return 0
  [ -n "$line" ] || return 0
  state_del baseFreshness
  local tmp; tmp="$(mktemp)"
  LCARS_BF_LINE="$line" awk 'NR==1{print; print ENVIRON["LCARS_BF_LINE"]; next} {print}' \
    "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# The ONE new event kind. It fires when the drive BEGAN against a base that was
# genuinely behind — whether or not LCARS could fix it — and never on a verdict
# that measured nothing (`unknown`, `child-base`): claiming staleness that was
# never established is the one lie a consumer cannot detect, the same doctrine
# that makes `behindBy` null rather than a reassuring 0.
#
# IDEMPOTENCE IS A FINGERPRINT, NOT A FLAG. The event carries `key` =
# verdict:behindBy:baseSha, and an identical key already in events.jsonl means
# this exact fact is already on the timeline — so a re-drive of an unchanged
# Mission adds nothing. A base that has since moved (or been fixed) has a
# different key and is a genuinely new fact, so it still gets logged.
drive_emit_base_stale() { # stage-at-drive-start
  local v="${LCARS_BASE_VERDICT:-}" n="${LCARS_BASE_BEHIND:-}" b="${LCARS_BASE_BRANCH:-}"
  case "$v" in updated|stale) : ;; *) return 0 ;; esac
  case "$n" in ''|0|*[!0-9]*) return 0 ;; esac
  local key detail
  key="$v:$n:${LCARS_BASE_SHA:-}"
  event_seen base_stale "\"key\":\"$key\"" && return 0
  if [ "$v" = "updated" ]; then
    detail="this drive began against a stale base — '$b' was $n commit(s) behind origin, and LCARS fast-forwarded it before the first Stage ran"
  else
    detail="this drive began against a stale base — '$b' is $n commit(s) behind origin and LCARS could not bring it up to date: ${LCARS_BASE_REASON:-no reason recorded}"
  fi
  emit_event base_stale "${1:-}" "$detail" \
    behindBy="$n" verdict="$v" base="$b" key="$key"
}

# The whole re-check, in caller order. Runs ONCE per drive.
drive_base_recheck() {
  drive_load_base_lib || return 0
  local base branch stage
  base="$(json_str "$STATE" base)"
  branch="$(json_str "$STATE" branch)"
  stage="$(json_str "$STATE" stage)"
  # No recorded base ⇒ nothing to check. Inventing one ("probably main") is the
  # substitution S158 refuses everywhere else in this record.
  [ -n "$base" ] || return 0
  ensure_base_current "$base"
  # THE MISSION'S OWN BRANCH IS THE ONE THAT DECIDES WHAT A STAGE READS, and it is
  # a separate fact from the BASE's freshness. `mission_branch_block` (this file,
  # ~line 574) pins every Research / Validate / Plan / Plan Review worker to
  # `lcars/<id>` and tells it to IGNORE the ambient checkout — so fast-forwarding
  # only the base leaves every Stage reasoning about the filing-time tree, which is
  # the whole failure S159 exists to close. The drive therefore advances the
  # mission branch too, but ONLY when that is LOSSLESS (no commits of its own);
  # one commit of its own and it is left alone with the loud ⚠ block and a rebase.
  #
  # NOT for a `child-base` Mission: a logged bug's base is its parent's branch,
  # LCARS takes no position on it, and the parent's branch is never moved.
  #
  # NOR while git is MID-OPERATION (S160 round 2). An unfinished rebase / merge /
  # cherry-pick / revert / bisect means the base ref is where the operation will
  # move it FROM, so "fast-forward the mission branch onto the base" would aim at
  # a commit that is about to stop existing — and the base's own verdict already
  # says nothing was measured. The guard carries that as one blocker token, so
  # this reads the record rather than re-deciding it.
  if [ "${LCARS_BASE_VERDICT:-}" != "child-base" ] \
     && [ "${LCARS_BASE_BLOCKER:-}" != "operation-in-progress" ]; then
    lcars_base_advance_mission_branch "$branch" "$base" || true
    lcars_base_branch_note_drive "$branch" "$base" || true
  fi
  # Persisted AFTER the advance, so `missionBranchAtBase` records what the branch
  # really is now — never a move that did not happen.
  drive_persist_base_freshness "$branch"
  drive_emit_base_stale "$stage"
  return 0
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

# S114 liveness: total output bytes across the worker's stdout+stderr (the SIZE
# fields of _file_size_mtime, summed). Feeds worker-liveness.json's outputBytes.
# Non-numeric/absent ⇒ counted as 0. Read-only — never touches the hang timer.
_liveness_output_bytes() { # outfile errfile → integer total bytes (stdout)
  local sa sb a b
  sa="$(_file_size_mtime "$1")"; sb="$(_file_size_mtime "$2")"
  a="${sa%% *}"; b="${sb%% *}"
  case "$a" in ''|*[!0-9]*) a=0 ;; esac
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  printf '%d' "$(( a + b ))"
}

# S114 liveness: write worker-liveness.json ATOMICALLY (tmp+mv, same dir → the
# server never reads a half-written file). Shape (all bare integers except the two
# short identifier strings): {"stage":..,"startedAt":N,"lastOutputTs":N,
# "outputBytes":N,"state":"thinking|producing|quiet"}. jq-free; the identifiers are
# our own stage keys / enum, so a plain quote is safe.
_liveness_write() { # file stage startedAt lastOutputTs outputBytes state
  local file="$1" stage="$2" started="$3" lastout="$4" bytes="$5" state="$6"
  local tmp="$file.tmp.$$"
  printf '{"stage":"%s","startedAt":%s,"lastOutputTs":%s,"outputBytes":%s,"state":"%s"}\n' \
    "$stage" "$started" "$lastout" "$bytes" "$state" >"$tmp" 2>/dev/null || return 0
  mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
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

  # === S114 liveness sidecar (ADDITIVE — ZERO effect on hang semantics) =======
  # A REAL liveness signal for the board, derived PURELY from the cpu/sig data the
  # hang guard already computes below (we only READ it; the stagnant/kill logic is
  # byte-for-byte unchanged). Maintain $MISSION_DIR/worker-liveness.json describing
  # whether the worker is producing output / thinking (burning CPU) / quiet, plus
  # startedAt + lastOutputTs so the server can compute staleness. No-op when there
  # is no $MISSION_DIR (e.g. the Align context-pack path). Finalized (removed) on
  # EVERY exit path (normal, break, HUNG) so a finished/dead worker shows nothing.
  #
  # Anti-thrash: the sidecar bumps the adapter fingerprint (SSE push), so writes
  # are STATE-CHANGE-driven and floored to at most one every LCARS_LIVENESS_MIN_WRITE
  # seconds (default 5) regardless of the poll interval — a chatty producing↔thinking
  # flip coalesces to ≤1 write / floor. Quiet-seconds staleness needs NO rewrite: the
  # server recomputes it from lastOutputTs on each read, so a steady state never
  # rewrites the file. This keeps SSE calm even at poll=1.
  local live_file="" live_min live_started live_last_out live_bytes live_prev_sig
  local live_state="" live_written="" live_last_write=0 live_stage
  if [ -n "${MISSION_DIR:-}" ] && [ -d "${MISSION_DIR:-}" ]; then
    live_file="$MISSION_DIR/worker-liveness.json"
    live_min="${LCARS_LIVENESS_MIN_WRITE:-5}"
    case "$live_min" in ''|*[!0-9]*) live_min=5 ;; esac
    live_stage="${LCARS_LIVENESS_STAGE:-}"
    live_started="$(date +%s)"
    live_last_out="$live_started"
    live_bytes="$(_liveness_output_bytes "$out_a" "$out_b")"
    live_prev_sig="$last_sig"
    live_state="thinking"
    # Immediate first write so the board lights up as soon as the worker starts.
    _liveness_write "$live_file" "$live_stage" "$live_started" \
      "$live_last_out" "$live_bytes" "$live_state"
    live_written="$live_state"; live_last_write="$live_started"
  fi

  while pid_alive "$cmd_pid"; do
    sleep "$poll" 2>/dev/null || break
    pid_alive "$cmd_pid" || break
    local cpu sig
    cpu="$(_pgid_cpu_sum "$cmd_pid")"
    sig="$(_file_size_mtime "$out_a")|$(_file_size_mtime "$out_b")"

    # --- S114 liveness derivation (READ-ONLY wrt the hang timer below) --------
    # Placed BEFORE the hang logic so a producing tick (which `continue`s below)
    # still updates liveness. producing ⇒ output actually GREW this tick (never a
    # lie); else thinking when burning CPU; else quiet. Write only on a real state
    # change AND only once per floor (coalesces flip-flop into a calm SSE stream).
    if [ -n "$live_file" ]; then
      local live_now new_state
      live_now="$(date +%s)"
      if [ "$sig" != "$live_prev_sig" ]; then
        new_state="producing"
        live_last_out="$live_now"
        live_bytes="$(_liveness_output_bytes "$out_a" "$out_b")"
      elif [ "$cpu" -gt "$cpu_min" ] 2>/dev/null; then
        new_state="thinking"
      else
        new_state="quiet"
      fi
      live_prev_sig="$sig"
      live_state="$new_state"
      if [ "$new_state" != "$live_written" ] \
         && [ "$(( live_now - live_last_write ))" -ge "$live_min" ]; then
        _liveness_write "$live_file" "$live_stage" "$live_started" \
          "$live_last_out" "$live_bytes" "$new_state"
        live_written="$new_state"; live_last_write="$live_now"
      fi
    fi

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
      [ -n "$live_file" ] && rm -f "$live_file" 2>/dev/null   # finalize: HUNG → no pulse
      return 137   # HUNG sentinel (128+SIGKILL) — see header
    fi
  done
  [ -n "$live_file" ] && rm -f "$live_file" 2>/dev/null   # finalize: exited → no pulse
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
  # A parked mission (prdPending) is NOT drivable — the driver never runs a
  # PRD-less mission. Refuse before taking the lock, naming the align command.
  refuse_if_parked

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

  # Version check (S129) — WARN mode ONLY. The drive loop is a headless,
  # walk-away path: it must NEVER prompt or block on the update ask. `warn` mode
  # prints at most one throttled line and never reads stdin; run once here at the
  # top (before the loop) so a cold-stage-spawning drive still surfaces staleness
  # without ever stopping. Fully guarded + kill-switch aware.
  local version_check="${LCARS_VERSION_CHECK_BIN:-$SKILL_DIR/../lcars-version/check.sh}"
  [ -f "$version_check" ] && bash "$version_check" warn </dev/null || true

  # BASE FRESHNESS (S159) — re-ask the question S158 asked at filing time, ONCE,
  # here: after the driver lock (so two drives can never fetch/fast-forward the
  # same base at once) and BEFORE the stage loop (so it is once per drive, not
  # once per Stage, and so the first Stage worker is spawned into the tree it
  # produced). It never blocks — see drive_base_recheck.
  drive_base_recheck

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

MISSION_ID=""; QFILE=""; RESPONSES=""; PLAN=""; VERDICT=""; TICKET=""; TESTS=""; STUBS=""; SETUP=""; RESULT=""; STEP=0
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
    --setup)       SETUP="${2:-}"; shift 2 ;;
    --setup=*)     SETUP="${1#--setup=}"; shift ;;
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
  gate|save|validate-pause|validate-advance|plan-save|review-save|schedule|impl-save-result|impl-status|impl-advance|verify-summary|open-pr|research|validate|estimate|plan|plan-review|implement|implement-ticket|drive|emit-event)
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
  # ACTUAL per-mission usage (session 112) — sums usage.json (the actuals cold
  # workers recorded on exit) per stage + total. Pure; the CLI-parity read surface.
  usage)            [ -n "$MISSION_ID" ] || die "usage: run.sh usage --mission <id>"
                    cmd_usage ;;
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
    __pwt="$(make_ticket_worktree "$MISSION_DIR/wt-test" "${RC_BRANCH:-$(json_str "$STATE" branch)}" "${TICKET:-all}")" \
      || { printf 'WT-ERR: make_ticket_worktree failed loud (no silent in-tree fallback)\n'; exit 1; }
    printf 'WT=%s\n' "$__pwt"
    exit 0 ;;
  # S133 test hook: exercise the preflight runner SELF-HEAL. Probes the runner in
  # the given dir (POSARG, default $REPO_ROOT); if dead and this is a worktree build
  # (LCARS_TICKET_WORKTREE) with a declared worktreeSetupCommand, re-applies it ONCE
  # and re-probes. Prints PREFLIGHT=ok|healed|dead. testCommand + setup command are
  # env-injectable ($LCARS_TEST_CMD / $LCARS_WORKTREE_SETUP_CMD) so a test drives it
  # with ZERO real spend. Always exits 0.
  preflight-heal-test)
    locate_mission "$MISSION_ID"
    if preflight_runner_or_heal "${POSARG:-$REPO_ROOT}"; then
      printf 'PREFLIGHT=%s\n' "${PREFLIGHT_HEALED:-ok}"
    else
      printf 'PREFLIGHT=dead\n'
    fi
    exit 0 ;;
  # S111 test hook: drive the REAL replay_ticket_commit (mutex + landing worktree)
  # for one commit object. Positional arg = the commit sha; --ticket defaults
  # t-001; --branch overrides state.json's. Prints REPLAY-OK, or REPLAY-ERR with
  # the recorded reason and exits 1 — so the sovereignty test can assert both the
  # landing AND that the captain's checkout was never touched.
  replay-test)
    locate_mission "$MISSION_ID"
    [ -n "$POSARG" ] || die "usage: run.sh replay-test --mission <id> [--ticket <t>] <commit-sha>"
    if replay_ticket_commit "${RC_BRANCH:-$(json_str "$STATE" branch)}" "$POSARG" "${TICKET:-t-001}"; then
      printf 'REPLAY-OK\n'; exit 0
    else
      printf 'REPLAY-ERR: %s\n' "${REPLAY_FAIL_REASON:-failed}"; exit 1
    fi ;;
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
  # output, the newline-separated files-written list, and the S131 applied-setup
  # flag are passed via env ($LCARS_CLASSIFY_WORKER_OUT / $LCARS_CLASSIFY_FILES /
  # $LCARS_CLASSIFY_SETUP_APPLIED, all default empty) so the precedence of
  # classify_impl_failure can be driven directly, offline + free.
  # Inert for every real subcommand — reachable only by this explicit token.
  classify-impl-failure-test)
    _ci_runner="$(cat)"
    classify_impl_failure "$_ci_runner" "${LCARS_CLASSIFY_WORKER_OUT:-}" "${LCARS_CLASSIFY_FILES:-}" "${LCARS_CLASSIFY_SETUP_APPLIED:-}"
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
    # S157 (additive — FSRC keeps its name, value and position): the ids the gate
    # attributed the regression to, and the pick self-heal would hand the
    # reconcile to, so the gate→attribution plumbing is provable without
    # dispatching a (billable) worker.
    printf 'FSREG=%s\n' "$FULL_SUITE_REGRESSED"
    printf 'FSPICK=%s\n' "$(selfheal_regressor "$FULL_SUITE_REGRESSED" "$__fsg_ordered" | tr '\t' '|')"
    exit 0 ;;
  # S92 test hook: exercise attachments_extra_block in ISOLATION. MISSION_DIR is
  # taken straight from $LCARS_ATT_TEST_DIR (no locate_mission, no worker spawn),
  # so a focused test can assert the block emits the ABSOLUTE attachment paths
  # when the dir has files and is empty when the dir is absent/empty.
  attachments-block-test)
    MISSION_DIR="${LCARS_ATT_TEST_DIR:-}"
    attachments_extra_block
    exit 0 ;;
  # S169 test hook, the same shape as the one above: exercise the Plan stage's
  # MOCKUP CONTRACT block in ISOLATION. MISSION_DIR comes from
  # $LCARS_ATT_TEST_DIR — no locate_mission, no worker spawn, zero tokens — so a
  # focused test can assert what the Planner is actually told, and assert that a
  # Mission WITHOUT a mockup gets nothing at all.
  plan-mockup-block-test)
    MISSION_DIR="${LCARS_ATT_TEST_DIR:-}"
    plan_mockup_contract_block
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
  # S133 test hook: declared-edits-aware drift over a ticket's proof-time test
  # snapshot (0 = clean or declared; 1 = UNDECLARED drift, rels echoed).
  proof-drift-test)
    locate_mission "$MISSION_ID"
    __pd_rc=0; __pd_out="$(proof_drift_declared_ok "$TICKET" "${POSARG:-$REPO_ROOT}")" || __pd_rc=$?
    [ -n "$__pd_out" ] && printf '%s\n' "$__pd_out"
    printf 'PDRC=%s\n' "$__pd_rc"; exit 0 ;;
  # S132 test hooks: the STANDALONE proof-of-work gates (no live implement path
  # calls these — the path flips in S133). Each drives the REAL gate function
  # against a mission fixture and prints its rc as a parseable token, so the
  # flip-flop / declared-edits / quality-floor / v2-result contracts are
  # exercised offline + token-free. Inert for every real subcommand.
  flip-flop-gate-test)
    locate_mission "$MISSION_ID"
    [ -n "$TICKET" ] || die "usage: run.sh flip-flop-gate-test --mission <id> --ticket <t> --sha <parent-sha> [worktree]"
    [ -n "$RC_SHA" ] || die "flip-flop-gate-test needs --sha <parent-sha> (the parent commit is the snapshot)."
    __ff_rc=0; flip_flop_gate "$TICKET" "$RC_SHA" "${POSARG:-$REPO_ROOT}" || __ff_rc=$?
    printf 'FFRC=%s\n' "$__ff_rc"; exit 0 ;;
  declared-edits-guard-test)
    locate_mission "$MISSION_ID"
    [ -n "$TICKET" ] || die "usage: run.sh declared-edits-guard-test --mission <id> --ticket <t> --sha <parent-sha> [worktree]"
    [ -n "$RC_SHA" ] || die "declared-edits-guard-test needs --sha <parent-sha>."
    __de_rc=0; declared_edits_guard "$TICKET" "$RC_SHA" "${POSARG:-$REPO_ROOT}" || __de_rc=$?
    printf 'DERC=%s\n' "$__de_rc"; exit 0 ;;
  proof-validate-result-test)
    __pv_rc=0; proof_validate_result "$RESULT" "$TICKET" || __pv_rc=$?
    printf 'PVRC=%s\n' "$__pv_rc"; exit 0 ;;
  # Drives the REAL commit_ticket in WORKTREE mode ($LCARS_TICKET_WORKTREE set by
  # the caller), so the multi-session cumulative-commit contract can be exercised
  # offline + token-free: N sessions in one worktree must leave .commit-sha naming
  # ONE commit carrying the ticket's WHOLE diff vs the wave base. Inert for every
  # real subcommand.
  commit-ticket-test)
    locate_mission "$MISSION_ID"
    [ -n "$TICKET" ] || die "usage: run.sh commit-ticket-test --mission <id> --ticket <t> [summary]"
    __ct_rc=0; commit_ticket "$TICKET" "${POSARG:-test session}" || __ct_rc=$?
    [ -n "${COMMIT_NOTE:-}" ] && printf '%s\n' "$COMMIT_NOTE"
    printf 'CTRC=%s\n' "$__ct_rc"; exit 0 ;;
  # S157 test hooks: the PURE regressor-attribution pair. Failing ids via
  # $LCARS_SHR_FAILING, plan order via $LCARS_SHR_ORDERED. `selfheal-regressor-test`
  # echoes "<id>\t<basis>"; `selfheal-attribution-test` echoes the premise line the
  # reconcile brief opens with, for the id/basis in $LCARS_SHR_ID/$LCARS_SHR_BASIS.
  # Pure string work — no mission, no worker, no git. Inert for real subcommands.
  selfheal-regressor-test)
    selfheal_regressor "${LCARS_SHR_FAILING:-}" "${LCARS_SHR_ORDERED:-}"
    exit 0 ;;
  selfheal-attribution-test)
    selfheal_attribution_note "${LCARS_SHR_ID:-}" "${LCARS_SHR_BASIS:-}"
    exit 0 ;;
  # S166 test hook: the PURE drive summary line. Stage output on stdin, the Stage
  # name as the positional, the outcome in $LCARS_DL_OUTCOME (ok|paused). Lets a
  # test hand `drive_line` an output shape the real Stages do not currently
  # produce — the whole point of a guard is what it does with the case that has
  # not happened yet. No mission, no worker, no git.
  drive-line-test)
    MISSION_DIR="${MISSION_DIR:-/nonexistent}"
    drive_line "${POSARG:-validate}" "$(cat)" "${LCARS_DL_OUTCOME:-ok}"
    printf '\n'
    exit 0 ;;
  # S157 C2 test hook: the PURE runner-count reader. Runner output on stdin;
  # prints the executed-test count, or nothing when it cannot read one.
  executed-count-test)
    printf '%s\n' "$(proof_executed_count "$(cat)")"
    exit 0 ;;
  proof-quality-floor-test)
    locate_mission "$MISSION_ID"
    [ -n "$TICKET" ] || die "usage: run.sh proof-quality-floor-test --mission <id> --ticket <t> --sha <parent-sha> [worktree]"
    [ -n "$RC_SHA" ] || die "proof-quality-floor-test needs --sha <parent-sha>."
    __qf_rc=0; proof_quality_floor "$TICKET" "$RC_SHA" "${POSARG:-$REPO_ROOT}" || __qf_rc=$?
    printf 'QFRC=%s\n' "$__qf_rc"; exit 0 ;;
  ''|*) die "unknown subcommand '${SUB:-}'. Usage: run.sh drive --mission <id> [--step], or a single Stage. Drivers: research|validate|plan|plan-review|implement|implement-ticket|drive. Persistence: gate|save|validate-pause|validate-advance|plan-save|review-save|schedule|impl-save-result|impl-status|impl-advance|verify-summary." ;;
esac
