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

# ---------------------------------------------------------------------------
# S223 fix round 1 (D4) — THE WRITE IS JSON-AWARE TOO
# ---------------------------------------------------------------------------
# S223 made every numberOne READ parse real JSON. The WRITE stayed the awk pass
# below, which edits LINES — so it only ever replaced the FIRST line of a value
# and left the rest of it loose at the top level:
#
#     "numberOne": {"status": "stood-down"},
#       "status": "engaged",        ← was inside the object
#     },                            ← a bare brace, now a "field"
#     "baseFreshness": {,           ← the next object's head, comma'd
#
# …which is not JSON. Every shipped writer puts `numberOne` on ONE line, so the
# harness never sees it — but the CAPTAIN'S state.json was REPAIRED BY HAND on
# 2026-09-19, and a hand repair is pretty-printed. A fresh tester reproduced the
# corruption on 6/6 missions, with a plain headline. The original data loss was
# re-armed by the shape of the file, not by the prose in it.
#
# So the write now goes through a real JSON parser first: python3 reads the
# file, LOCATES the top-level key with `json.JSONDecoder` (never a regex, never
# a line), and SPLICES the new value over exactly that span. Every other byte of
# the file — order, indentation, comments-free whitespace, the one-line
# `numberOne`/`baseFreshness` invariant readers depend on — is carried through
# untouched, which a `json.dump` round-trip could not promise.
#
# The awk pass stays, and stays authoritative, for everything python3 declines:
#   * no python3 on the machine (respond.sh's fallback exists for this reason) —
#     the writer is the one function that may never be unavailable;
#   * a file that is NOT valid JSON — awk REPAIRS a dangling comma a pre-S207
#     writer left behind, and that repair must not be lost;
#   * a file that is not the one-object-per-file shape LCARS writes — awk's
#     loud no-op and its refusal latch are the contract (S207 fix round 1, D2).
# python3 signals "not mine" with rc 3 and writes nothing; bash then runs awk
# exactly as before. Nothing about the refusal contract moves.
_LCARS_STATE_PY="${LCARS_STATE_PY:-python3}"

# _lcars_state_put_json <file> <key> <mode:str|raw|del> [value]
#   rc 0 → written; anything else → not handled, fall through to awk.
_lcars_state_put_json() {
  command -v "$_LCARS_STATE_PY" >/dev/null 2>&1 || return 3
  # stderr is dropped on purpose: anything python3 cannot do here is a DEFER,
  # and awk then does the write — a traceback in front of the captain for a
  # write that then succeeds would be noise, not news.
  F="$1" K="$2" MODE="$3" V="${4:-}" "$_LCARS_STATE_PY" - 2>/dev/null <<'PY'
import json, os, sys
from json import JSONDecoder
from json.decoder import scanstring

path, key, mode, val = (os.environ["F"], os.environ["K"],
                        os.environ["MODE"], os.environ.get("V", ""))
DEFER = 3                       # "not mine" — the awk pass owns this file


def defer():
    sys.exit(DEFER)


try:
    with open(path, "r") as fh:
        text = fh.read()
except OSError:
    defer()

# THE SHAPE GATE, unchanged from the awk pass: `{` opens it, a line that is `}`
# alone closes it. A valid but COMPACT state.json is still refused (S207 fix
# round 1, D2 — a loud no-op, never a silent rewrite), so it goes to awk.
lines = text.split("\n")
if len(lines) < 2 or not any(l.strip() == "}" for l in lines[1:]):
    defer()
try:
    doc = json.loads(text)
except ValueError:
    defer()                     # awk repairs what a pre-S207 writer corrupted
if not isinstance(doc, dict):
    defer()

# WHERE EACH TOP-LEVEL FIELD REALLY IS, read by the json module itself.
dec = JSONDecoder()


def spans(s):
    i = s.index("{") + 1
    out = []
    while True:
        while i < len(s) and s[i] in " \t\r\n":
            i += 1
        if i >= len(s):
            defer()
        if s[i] == "}":
            return out, i
        if s[i] != '"':
            defer()
        kstart = i
        try:
            name, i = scanstring(s, i + 1)
        except ValueError:
            defer()
        while i < len(s) and s[i] in " \t\r\n":
            i += 1
        if i >= len(s) or s[i] != ":":
            defer()
        i += 1
        while i < len(s) and s[i] in " \t\r\n":
            i += 1
        vstart = i
        try:
            _, i = dec.raw_decode(s, vstart)
        except ValueError:
            defer()
        out.append((name, kstart, vstart, i))
        while i < len(s) and s[i] in " \t\r\n":
            i += 1
        if i < len(s) and s[i] == ",":
            i += 1
            continue
        if i < len(s) and s[i] == "}":
            return out, i
        defer()


try:
    fields, close = spans(text)
except (ValueError, IndexError):
    defer()

hit = next((j for j, f in enumerate(fields) if f[0] == key), -1)
token = val if mode != "str" else '"%s"' % val

if mode == "del":
    if hit < 0:
        sys.exit(0)             # nothing to do IS a success (S207's contract)
    _, kstart, _, vend = fields[hit]
    if len(fields) == 1:
        out = text[:kstart] + text[vend:]
    elif hit < len(fields) - 1:
        out = text[:kstart] + text[fields[hit + 1][1]:]
    else:
        out = text[:fields[hit - 1][3]] + text[vend:]
elif hit >= 0:
    # THE WHOLE VALUE, however many lines it spans — this is the cure.
    out = text[:fields[hit][2]] + token + text[fields[hit][3]:]
elif not fields:
    o = text.index("{") + 1
    out = text[:o] + '\n  "%s": %s' % (key, token) + text[o:]
else:
    # A NEW key goes directly after the opening brace, where every writer since
    # S207 has put it. The position is not load-bearing; churn would be.
    k0 = fields[0][1]
    out = text[:k0] + '"%s": %s,\n  ' % (key, token) + text[k0:]

try:
    json.loads(out)             # never hand back something that will not parse
except ValueError:
    defer()
tmp = path + ".lcars-tmp"
try:
    with open(tmp, "w") as fh:
        fh.write(out)
    os.replace(tmp, path)
except OSError:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    defer()
PY
}

# S223 fix round 3 (D1) — THE INPUT IS VALIDATED, NOT JUST THE OUTPUT
#
# Fix round 2 made the awk path check that its RESULT parses. A whole family
# walked straight through that: garbage APPENDED AFTER the closing brace. awk
# finds the last line that is `}` alone and rebuilds up to it, so the trailing
# content is DROPPED — the output parses, the check passes, the write lands,
# and the captain is told "stood down" on exit 0 while his file comes back
# valid JSON with his content silently deleted. A fresh tester reproduced it
# with one appended line on a flat state.json.
#
# So the file AS IT EXISTS ON DISK must parse before anything is written. The
# ONE exception is awk's known-good repair: a pre-S207 writer left a dangling
# separator comma (`{ "a": 1, }`), which is not valid JSON either and which
# awk's rebuild cures. That, and only that, is still let through — decided by
# asking whether removing dangling commas (outside strings) is enough to make
# the file parse. Anything else — trailing junk, a second document, a stray
# brace — is refused loudly with nothing written.
#
# _lcars_state_input_ok <file> — rc 0 when the awk pass may touch this file.
_lcars_state_input_ok() {
  command -v "$_LCARS_STATE_PY" >/dev/null 2>&1 || return 0   # no oracle, no gate
  F="$1" "$_LCARS_STATE_PY" - 2>/dev/null <<'PY'
import json, os, sys

try:
    text = open(os.environ["F"]).read()
except OSError:
    sys.exit(0)                  # not ours to judge; the caller's guards apply
try:
    json.loads(text)
    sys.exit(0)                  # already valid — nothing to decide
except ValueError:
    pass

# THE ONE KNOWN-GOOD REPAIR. Walk the text so a comma inside a quoted value is
# never mistaken for a separator, and drop any comma whose next non-space
# character closes an object or an array. This text is only used to DECIDE;
# the write itself is still awk's, byte for byte.
out, i, n, in_str, esc = [], 0, len(text), False, False
while i < n:
    c = text[i]
    if in_str:
        out.append(c)
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif c == '"':
            in_str = False
    elif c == '"':
        in_str = True
        out.append(c)
    elif c == ",":
        j = i + 1
        while j < n and text[j].isspace():
            j += 1
        if j < n and text[j] in "}]":
            pass                 # a dangling separator — the repair drops it
        else:
            out.append(c)
    else:
        out.append(c)
    i += 1
try:
    json.loads("".join(out))
    sys.exit(0)                  # a dangling comma and nothing else: awk cures it
except ValueError:
    sys.exit(1)                  # awk cannot know what this is. Refuse.
PY
}

# Live operator controls opt in locally; the flag is never exported to workers.
# Record the actual input/output bytes, not fields, times, or a later diff.
lcars_operator_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    cksum "$1" | awk '{print $1 "-" $2}'
  fi
}

lcars_operator_lock() { # mission-dir
  local n
  for ((n=0; n<100; n++)); do
    mkdir "$1/.operator-write-lock" 2>/dev/null && return 0
    sleep 0.05
  done
  printf 'LCARS: cannot lock operator write record in %s; refusing an unauditable write/read. Inspect .operator-write-lock before retrying.\n' "$1" >&2
  return 1
}

lcars_operator_append() { printf '%s\n' "$2" >> "$1"; }

lcars_operator_write() { # file command [args]; command receives a private file first
  local file="$1" control="${_LCARS_OPERATOR_CONTROL:-}" dir tmp before after rc=0
  shift
  dir="$(dirname "$file")"
  lcars_operator_lock "$dir" || exit 1
  if ! tmp="$(mktemp "$dir/.operator-write.XXXXXX")"; then
    rmdir "$dir/.operator-write-lock"
    printf 'LCARS: cannot stage operator write to %s.\n' "$file" >&2
    exit 1
  fi
  if [ -f "$file" ]; then
    if ! cp -p "$file" "$tmp"; then
      rm -f "$tmp"; rmdir "$dir/.operator-write-lock"
      printf 'LCARS: cannot copy operator write input %s.\n' "$file" >&2
      exit 1
    fi
    if ! before="$(lcars_operator_hash "$tmp")"; then
      rm -f "$tmp"; rmdir "$dir/.operator-write-lock"
      printf 'LCARS: cannot fingerprint operator write input %s.\n' "$file" >&2
      exit 1
    fi
  else
    before=ABSENT
  fi
  # The existing writer edits the captured input, never a second read of state.
  local _LCARS_OPERATOR_CONTROL=""
  local command="$1"; shift
  if [ "$rc" -eq 0 ]; then "$command" "$tmp" "$@"; rc=$?; fi
  if [ "$rc" -eq 0 ]; then
    if ! after="$(lcars_operator_hash "$tmp")"; then
      rm -f "$tmp"; rmdir "$dir/.operator-write-lock"
      printf 'LCARS: cannot fingerprint operator write output %s.\n' "$file" >&2
      exit 1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    if ! mv -f "$tmp" "$file"; then
      rm -f "$tmp"; rmdir "$dir/.operator-write-lock"
      printf 'LCARS: cannot publish operator write to %s.\n' "$file" >&2
      exit 1
    elif ! printf '%s\t%s\t%s\t%s\n' "${file##*/}" "$before" "$after" "$control" \
        >> "$dir/operator-writes.tsv"; then
      rmdir "$dir/.operator-write-lock"
      printf 'LCARS: wrote %s but could not record the operator write; the fence will NOT excuse it.\n' "$file" >&2
      exit 1
    fi
  fi
  rm -f "$tmp"
  rmdir "$dir/.operator-write-lock" || exit 1
  # Keep the existing refusal latch naming the real state, not the private copy.
  LCARS_STATE_REFUSED="${LCARS_STATE_REFUSED//$tmp/$file}"
  return "$rc"
}

# _lcars_state_put <file> <key> <mode:str|raw|del> [value]
_lcars_state_put() {
  local file="$1" tmp rc=0
  [ -n "$file" ] && [ -f "$file" ] || return 0
  if [ -n "${_LCARS_OPERATOR_CONTROL:-}" ] && [ "${file##*/}" = state.json ]; then
    shift
    lcars_operator_write "$file" _lcars_state_put "$@"
    return $?
  fi
  _lcars_state_put_json "$@" && return 0
  if ! _lcars_state_input_ok "$file"; then
    LCARS_STATE_REFUSED="$file (field \"$2\") — it is not valid JSON, and the writer could not repair it"
    printf '  ⚠ %s is not valid JSON — left untouched (field "%s" NOT written).\n' \
      "$file" "$2" >&2
    return 1
  fi
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
    # S223 fix round 2 (D3) — AWK MAY NOT HAND BACK SOMETHING THAT WILL NOT
    # PARSE. awk edits LINES, and on a file that is ALREADY broken JSON it
    # happily "succeeds": a tester appended garbage to a state.json, ran
    # `lcars xo off`, got exit 0 and "stood down on …", and the file came back
    # with a stray comma after every opening brace (`"baseFreshness": {,`).
    # A silent lie, and the file left worse than it was found.
    #
    # THE AWK REPAIR IS KEPT. A pre-S207 writer left a dangling comma behind,
    # awk's rebuild cures it, and that repaired output IS valid JSON — it
    # passes this check and still lands. Only a write whose RESULT still will
    # not parse is refused, which is exactly the case where awk cannot know
    # what it is editing. The python3 path already makes this promise about
    # its own output; this gives awk the same one. With no python3 on the
    # machine the write goes through as before — the writer may never be
    # unavailable, and that is the older of the two contracts.
    if command -v "$_LCARS_STATE_PY" >/dev/null 2>&1 \
       && ! "$_LCARS_STATE_PY" -c 'import json,sys; json.load(open(sys.argv[1]))' \
            "$tmp" >/dev/null 2>&1; then
      rc=1
      rm -f "$tmp"
      LCARS_STATE_REFUSED="$file (field \"$2\") — it is not valid JSON, and the writer could not repair it"
      printf '  ⚠ %s is not valid JSON — left untouched (field "%s" NOT written).\n' \
        "$file" "$2" >&2
    else
      mv "$tmp" "$file"
    fi
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
# S223 — THESE ARE NOW JSON-AWARE. They used to be sed regexes (`{[^}]*}`,
# `"[^"]*"`) and the comment here said "the moment a value could contain a `{`,
# a `}` or a quote these stop being correct, so every WRITER controls its own
# values". That promise did not hold: a verdict's HEADLINE is prose, it reached
# the object, and `lcars xo off <mission>` on the captain's real repo read a
# truncated numberOne back and wrote the truncation over his state.json.
#
# So every read and write of a top-level key now goes through ONE scanner,
# `_lcars_json_top`, which walks the text character by character, knows when it
# is inside a string (and inside an escape), and counts depth — a `}` inside a
# quoted value is text, not the end of the object. Still bash + awk only, for
# the reason the writer above gives. A value is ANY JSON value (string, number,
# bool, a nested object); the string helpers escape and unescape properly.
#
# _lcars_json_top <mode> <key> [raw-value]  (object text on stdin)
#   get  → the key's RAW value (rc 1 when absent)
#   del  → the object without that key
#   set  → the object with the key removed and re-appended at the end
#          (the old sed pair's order, kept so nothing downstream churns)
_lcars_json_top() {
  MODE="$1" K="$2" V="${3:-}" awk '
    BEGIN { RS = "\034"; mode = ENVIRON["MODE"]; key = ENVIRON["K"]; val = ENVIRON["V"] }
    { s = s $0 }
    function trim(t) { sub(/^[ \t\r\n]+/, "", t); sub(/[ \t\r\n]+$/, "", t); return t }
    END {
      n = length(s); depth = 0; instr = 0; esc = 0; expect = 0; inkey = 0
      m = 0; ostart = 0; oend = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (instr) {
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") {
            instr = 0
            if (inkey) { inkey = 0; kname[m] = substr(s, ks[m] + 1, i - ks[m] - 1) }
          }
          continue
        }
        if (c == "\"") {
          instr = 1
          if (depth == 1 && expect) { m++; ks[m] = i; vs[m] = 0; ve[m] = 0; inkey = 1; expect = 0 }
          continue
        }
        if (c == "{" || c == "[") {
          depth++
          if (depth == 1 && c == "{" && !ostart) { ostart = i; expect = 1 }
          continue
        }
        if (c == ":" && depth == 1 && m > 0 && !vs[m]) { vs[m] = i + 1; continue }
        if (c == "," && depth == 1) { if (m > 0 && !ve[m]) ve[m] = i; expect = 1; continue }
        if (c == "}" || c == "]") {
          if (depth == 1 && c == "}") { if (m > 0 && !ve[m]) ve[m] = i; oend = i }
          depth--
          if (depth == 0 && oend) break
          continue
        }
      }
      if (!ostart || !oend) exit 2        # not an object we can read: say nothing
      hit = 0
      for (j = 1; j <= m; j++) if (kname[j] == key && vs[j] && ve[j]) { hit = j; break }
      if (mode == "get") {
        if (!hit) exit 1
        printf "%s", trim(substr(s, vs[hit], ve[hit] - vs[hit]))
        exit 0
      }
      out = ""; sep = ""
      for (j = 1; j <= m; j++) {
        if (!ve[j] || (kname[j] == key)) continue
        out = out sep trim(substr(s, ks[j], ve[j] - ks[j])); sep = ", "
      }
      if (mode == "set") { out = out sep "\"" key "\": " val }
      printf "{%s}", out
    }'
}

# _lcars_json_unstr — a JSON string literal on stdin → its plain text (rc 1 if
# the value is not a string: a number, a bool, an object).
_lcars_json_unstr() {
  awk 'BEGIN { RS = "\034" } { s = s $0 }
    END {
      if (substr(s, 1, 1) != "\"" || substr(s, length(s), 1) != "\"" || length(s) < 2) exit 1
      s = substr(s, 2, length(s) - 2); n = length(s); o = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c != "\\") { o = o c; continue }
        i++; d = substr(s, i, 1)
        if (d == "n") o = o "\n"; else if (d == "t") o = o "\t"
        else if (d == "r") o = o "\r"; else if (d == "b") o = o "\b"
        else if (d == "f") o = o "\f"
        else if (d == "u") {
          # \u00XX (what _lcars_state_escape writes for a control char) is
          # decoded; any wider code point is kept as its escape, untouched.
          h = tolower(substr(s, i + 1, 4)); v = 0; okh = (length(h) == 4)
          for (q = 1; q <= 4 && okh; q++) { x = index("0123456789abcdef", substr(h, q, 1))
            if (!x) okh = 0; else v = v * 16 + x - 1 }
          if (okh && v > 0 && v < 128) { o = o sprintf("%c", v); i += 4 }
          else o = o "\\u"
        }
        else o = o d
      }
      printf "%s", o
    }'
}

lcars_json1_get() { # <obj> <key> — a STRING value, unescaped; empty for absent / non-string
  local raw
  raw="$(printf '%s' "$1" | _lcars_json_top get "$2")" || return 0
  printf '%s' "$raw" | _lcars_json_unstr || true
}
lcars_json1_raw() { # <obj> <key> — the key's raw JSON value, or empty
  printf '%s' "$1" | _lcars_json_top get "$2" || true
}
lcars_json1_del() { # <obj> <key> — the object without that key
  local out
  out="$(printf '%s' "${1:-}" | _lcars_json_top del "$2")" || out="${1:-}"
  printf '%s' "$out"
}
lcars_json1_set() { # <obj> <key> <raw-json-value> — replace or append, order-stable
  local obj="${1:-}" out
  [ -n "$obj" ] || obj='{}'
  if ! out="$(printf '%s' "$obj" | _lcars_json_top set "$2" "$3")"; then
    out="$(printf '{}' | _lcars_json_top set "$2" "$3")"
  fi
  printf '%s' "$out"
}
lcars_json1_str() { # <plain> — a JSON string literal (quotes, backslashes, control chars escaped)
  printf '"%s"' "$(_lcars_state_escape "$1")"
}

# lcars_state_get_raw <file> <key> — a top-level field's RAW JSON value off a
# state.json / config.json, read by the same scanner (never a `{[^}]*}` sed).
# Empty when the file or key is absent.
lcars_state_get_raw() {
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  _lcars_json_top get "$2" <"$1" || true
}
# lcars_state_xo_block <file> — the one-line `numberOne` OBJECT, or empty. THE
# reader for every script that used to sed for it (S223).
lcars_state_xo_block() {
  local raw
  raw="$(lcars_state_get_raw "${1:-}" numberOne)"
  case "$raw" in "{"*"}") printf '%s' "$raw" ;; esac
}
