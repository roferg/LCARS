#!/usr/bin/env bash
#
# lcars-state.sh — THE state.json field writer, and nothing else.
#
# Sourceable, self-contained (bash + awk + sed only; it does NOT depend on
# lcars-common.sh, and lcars-common.sh sources IT), and side-effect free: it
# defines functions and runs nothing.
#
#     . "$(dirname "$0")/../lcars-init/lcars-state.sh"
#
# Every script that edits a Mission's state.json sources this file. Before
# S207 they each carried their own copy of the same three functions, and every
# copy shared the same defect — see below.
# ---------------------------------------------------------------------------
# S207 — THE ONE state.json FIELD WRITER
# ---------------------------------------------------------------------------
# Before this, EIGHT scripts each carried their own copy of the same trio —
# a deleter, a string setter and a raw setter — and every copy carried the same
# defect. The deleter was a `grep -v` for the key's line; the setters called it
# and then re-inserted the field after the opening brace with a HARD-CODED
# TRAILING COMMA. Both halves are positional, and both break on the LAST field
# of the object:
#
#   * deleting the last field leaves the previous line's separator comma
#     dangling → `{ … "created": "…", }` → INVALID JSON;
#   * every `set` goes through that same delete first.
#
# S189 hit it for real — adopt's refresh path corrupted a mission's state.json
# and the viewscreen, which parses for real, silently DROPPED the card while
# `lcars status` (sed-based) carried on as if nothing had happened. S189 cured
# the adopt.sh copy with the awk pass below and LEDGERED the other seven:
# "fix all writers together, one session, not mid-cure". S202 then made the
# window reachable in ordinary use — answering a gate clears `awaitingHuman`
# and `pendingQuestion`, and either can be the object's last field. This is
# that session, and this is that one writer.
#
# THE RULE: the comma is a property of POSITION, not of a line. Every write
# re-derives the separators over whatever the object ends up containing, so
# only the last field carries none — for any key, including the last one, for a
# single-field object, and for an object a previous writer already corrupted
# (this repairs it). An EXISTING key is updated IN PLACE, which keeps file.sh's
# field order and makes a repeat write byte-stable. A NEW key still goes in
# directly after the opening brace, which is exactly where all eight copies put
# it: the position is no longer load-bearing now that the writer is safe, but
# changing it would churn every state.json in existence for nothing.
#
# WHY awk AND NOT python3, which the session brief offered:
#   * python3 is not guaranteed on every machine LCARS runs on (respond.sh
#     carries a no-python3 fallback path for exactly this reason), and the
#     writer is the one function that cannot be allowed to be unavailable;
#   * `json.load` → `json.dump` would REFORMAT the whole file. Two fields must
#     stay on ONE line — `numberOne` (xo.sh's `state_xo_block`, run.sh's
#     `drive_xo_block` and `drive_xo_repo_on` all `sed` for `{…}` on one line)
#     and `baseFreshness` (lcars_base_state_line says so in its own comment) —
#     and every sed/awk reader in LCARS assumes one field per line. A reformat
#     would quietly break readers this session is not allowed to touch.
# So the writer depends on nothing but bash and awk. python3 appears only in
# the TESTS, as the independent oracle that the output really parses.
#
# PRECONDITION, and it is LCARS's own invariant: state.json is one field per
# line, `{` alone on the first line and `}` alone on the last. A file that is
# not that shape is LEFT EXACTLY AS IT WAS and a warning goes to stderr — a
# loud no-op, never a silent corruption.
#
# S207 fix round 1 (D2) — A REFUSAL RETURNS NON-ZERO, AND THE VERB MUST SAY SO.
# The writer used to return 0 unconditionally, including when it refused. A
# fresh tester handed `lcars pause` a valid but COMPACT state.json: the writer
# correctly warned and wrote nothing, and pause.sh then printed "PAUSE: paused
# lcars-…", "⏸ Mission will stop at the next safe boundary" and exited 0. The
# mission was not paused. A loud no-op that the caller cannot see is still a
# lie by the time it reaches the captain.
#
# So the contract is now:
#   * a successful write            → 0
#   * a legitimate nothing-to-do    → 0   (unsetting a key that is not there —
#                                          the object IS the shape, the awk pass
#                                          ran, the field simply was not present)
#   * no file to write to at all    → 0   (unchanged: several callers resolve a
#                                          mission by directory alone and call
#                                          through with no state.json; that is a
#                                          caller's guard, not a refused write)
#   * a REFUSAL — a real file the writer will not touch → 1, and the refusal is
#     latched in $LCARS_STATE_REFUSED so the VERB can say it plainly and exit
#     non-zero instead of announcing success.
#
# No LCARS script runs under `set -e` (they are all `set -uo pipefail`), so the
# new return code aborts nothing on its own — every reaction below is explicit,
# at the point where a verb would otherwise have claimed the write happened.
#
# $LCARS_STATE_REFUSED is deliberately NOT exported: a refusal belongs to the
# process that suffered it, and a child's refusal must not latch its parent (or
# the reverse).
#
# Values: `lcars_state_set` takes a RAW JSON token the caller owns (true,
# false, a number, a quoted string, a one-line object).
# `lcars_state_set_string` takes plain text and escapes it.
# Additive keys stay ABSENT rather than null: to remove one, unset it.

# A JSON-string-safe escape (no surrounding quotes): backslash and quote via
# bash, then awk turns every control character into an escape (newline/tab/CR →
# \n \t \r, the rest → \u00XX) so a multi-line value still yields VALID JSON
# on ONE line. jq-free, and deliberately a private copy of lcars-common.sh's
# lcars_json_escape rather than a call to it: this file must stand alone.
_lcars_state_escape() {
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

# The LATCH: the last write this process REFUSED, as "<file> (field \"<key>\")".
# Empty means nothing has been refused. Initialised here so `set -u` callers can
# read it before any write.
: "${LCARS_STATE_REFUSED:=}"

# _lcars_state_put <file> <key> <mode:str|raw|del> [value]
_lcars_state_put() {
  local file="$1" tmp rc=0
  [ -n "$file" ] && [ -f "$file" ] || return 0
  if ! tmp="$(mktemp)"; then
    LCARS_STATE_REFUSED="$file (field \"$2\") — no temporary file"
    printf '  ⚠ could not create a temporary file — %s left untouched (field "%s" NOT written).\n' \
      "$file" "$2" >&2
    return 1
  fi
  if K="$2" MODE="$3" V="${4:-}" awk '
    function rendered(   q) { q = (mode == "str") ? "\"" : ""
                              return "  \"" key "\": " q val q }
    BEGIN { key   = ENVIRON["K"]; mode = ENVIRON["MODE"]; val = ENVIRON["V"]
            # ANCHORED at the start of the line, so a VALUE that happens to
            # contain `"stage":` is never mistaken for the field itself.
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
        sub(/,[[:space:]]*$/, "", l)    # the SEPARATOR only; a comma inside a
                                        # quoted value is not at end-of-line.
        if (l ~ keyre) {
          if (mode == "del") continue
          l = rendered(); seen = 1
        }
        out[++n] = l
      }
      print line[1]
      if (mode != "del" && seen == 0) printf "%s%s\n", rendered(), (n > 0 ? "," : "")
      for (i = 1; i <= n; i++) printf "%s%s\n", out[i], (i < n ? "," : "")
      print line[close_i]
    }
  ' "$file" >"$tmp"; then
    mv "$tmp" "$file"
  else
    rc=1
    rm -f "$tmp"
    LCARS_STATE_REFUSED="$file (field \"$2\")"
    printf '  ⚠ %s is not the one-field-per-line object LCARS writes — left untouched (field "%s" NOT written).\n' \
      "$file" "$2" >&2
  fi
  return "$rc"
}

# --- HOW A VERB REACTS TO A REFUSAL ----------------------------------------
# lcars_state_refused  — rc 0 when THIS process has had a write refused.
lcars_state_refused() { [ -n "${LCARS_STATE_REFUSED:-}" ]; }

# lcars_state_refusal_die <verb> — say plainly that the write was refused and
# why, then exit non-zero. Called by a verb IMMEDIATELY BEFORE it would print
# its success line, so the captain never reads "paused" for a mission that is
# not paused. A no-op when nothing was refused, so it is safe on every path.
lcars_state_refusal_die() { # <verb>
  lcars_state_refused || return 0
  printf '%s: REFUSED — the Mission was NOT changed.\n' "${1:-lcars}" >&2
  printf '  %s\n' "$LCARS_STATE_REFUSED" >&2
  printf '  That state.json is not the one-field-per-line object LCARS writes, so the\n' >&2
  printf '  writer left it exactly as it was rather than risk corrupting it. Nothing was\n' >&2
  printf '  written and nothing else in this command took effect.\n' >&2
  printf '  Put it back to one field per line (`{` alone on the first line, `}` alone on\n' >&2
  printf '  the last), then run this again.\n' >&2
  exit 1
}

# lcars_state_set <file> <key> <raw-json-value>  — true/false/number/"quoted"/{…}
lcars_state_set()        { _lcars_state_put "$1" "$2" raw "$3"; }
# lcars_state_set_string <file> <key> <plain-text> — escaped and quoted for you
lcars_state_set_string() { _lcars_state_put "$1" "$2" str "$(_lcars_state_escape "$3")"; }
# lcars_state_unset <file> <key> — remove the field entirely (never write null)
lcars_state_unset()      { _lcars_state_put "$1" "$2" del; }

# ---------------------------------------------------------------------------
# S207 — THE ONE ONE-LINE-JSON-OBJECT EDITOR
# ---------------------------------------------------------------------------
# `numberOne` is a flat object of scalars living on ONE line of state.json (and
# of config.json, whose merge rule REQUIRES one line). S201 gave xo.sh
# `obj_get`/`obj_del`/`obj_set`, and S202 needed the same three inside run.sh's
# drive loop and copied them verbatim into `drive_xo_put` / `drive_xo_del`,
# whose own comment says: "S207's aftercare owns unifying the state writers
# repo-wide; making a 42nd shape here to be different would be the opposite of
# helping it." This is that unification — the copies are gone and both callers
# are these functions.
#
# Deliberately NOT a general JSON library: the moment a value could contain a
# `{`, a `}` or a quote these stop being correct, so every WRITER controls its
# own values (a status word, a cksum, an engine name). `lcars_json1_str` is how
# one is made.
lcars_json1_get() { # <obj> <key> — a string value, or empty
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
lcars_json1_del() { # <obj> <key> — the object without that key
  printf '%s' "$1" \
    | sed -E "s/\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[^,}]+)[[:space:]]*,?[[:space:]]*//" \
    | sed -E 's/,[[:space:]]*\}/}/; s/\{[[:space:]]*,[[:space:]]*/{/'
}
lcars_json1_set() { # <obj> <key> <raw-json-value> — replace or append, order-stable
  local obj="${1:-}" inner
  [ -n "$obj" ] || obj='{}'
  inner="$(lcars_json1_del "$obj" "$2")"
  inner="${inner#\{}"; inner="${inner%\}}"
  inner="$(printf '%s' "$inner" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/,$//')"
  if [ -n "$inner" ]; then printf '{%s, "%s": %s}' "$inner" "$2" "$3"
  else printf '{"%s": %s}' "$2" "$3"; fi
}
lcars_json1_str() { # <plain> — a JSON string literal for a value we control
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}
