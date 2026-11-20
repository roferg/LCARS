#!/usr/bin/env bash
#
# chunk-owners.sh — THE ONE READER AND WRITER OF "WHICH SUB-ECH OWNS THIS BUG".
#
# S365. The captain's model of 2026-11-20: AUTHORITY TRAVELS WITH THE CHUNK. A
# sub-ECH owns a chunk, hands it to the factory, makes sure it lands, validates
# it, FILES ITS OWN BUGS and DRIVES ITS OWN FIXES. The main ECH owns the overall
# ask and verifies the whole at the end.
#
# WHY A FILE AND NOT A FIELD IN `autopilot.json`. TWO scripts have to agree
# about what a blocker is, and they are written in two different styles:
# `ech.sh` reads JSON through python, `approve.sh` reads it with `sed` and has
# NO python dependency at all. The repo's own comment on the open-children gate
# says it best — the gate and the folder use "deliberately the same reader … so
# the two can never disagree about what a child is". A second JSON reader in
# the accept path is precisely how two gates come to disagree, so the fact both
# of them need is kept in a flat, greppable, append-only file instead:
#
#     .git/lcars/chunk-owners          <mission-id>\t<delegate-id>
#
# APPEND-ONLY, LATEST LINE WINS, and a RELEASE drops a delegate's lines. The
# shape is the questions ledger's and the tier ledger's, for the same reason:
# nothing is destroyed on write and the history stays readable.
#
# A MISSING FILE MEANS "NO SUB-ECH OWNS ANYTHING", WHICH IS EVERY REPO THAT HAS
# NEVER MINTED ONE — so every surface that reads this degrades to exactly the
# behaviour it had before S365. That is the known-good control, mechanised: the
# feature cannot engage where nobody asked for it.
#
# OWNERSHIP IS RELEASED WHEN THE SUB-ECH IS CLOSED. A closed sub-ECH drives
# nothing, so `lcars-ech delegate close` calls `lcars_chunk_release`. That is
# what lets the flat file carry a LIVE fact — "a bug an OPEN sub-ECH is
# driving" — without either reader having to parse a delegate's status.
#
# A CLAIM IS STILL ONLY A CLAIM, AND THE ECH CHECKS IT. A hand-written line
# naming a delegate no record backs must never buy an accept, so `lcars-ech
# land` cross-checks every owner against `delegates.<id>` with its own reader
# and refuses an unbacked claim by name. This library records and reads; it
# does not adjudicate.

# lcars_chunk_owners_file <lcars-dir> → the path of the ownership record
lcars_chunk_owners_file() {
  printf '%s/chunk-owners' "${1%/}"
}

# WHAT A ROW MEANS, AND IT IS TWO THINGS (S365 fix round 1). A row is written
# for a BUG a sub-ECH filed with `file-bug` — the row that stops that filing
# ending the parent's run — and for a MISSION a sub-ECH filed through
# `lcars-ech exec`, which is the captain's own definition of a chunk: *"they can
# sub divide the missions they feed the factory as it makes sense."* One record
# and one reader for both, because a second notion of ownership is a second
# answer to "whose work is this". The two never collide: a Mission id and a bug
# Mission id are both mission ids and each appears at most once as a key.
#
# WHO READS WHICH. The accept gates (`land`, `approve.sh`) only ever ask about a
# `type: bug` child of the Mission being landed, so a Mission row can never make
# a blocker go quiet. `mission_in_chunk` asks about any Mission.

# lcars_chunk_claim <lcars-dir> <mission-id> → the delegate id the record
# CLAIMS for it, with NO adjudication at all. The LAST matching line wins,
# because the record is appended.
#
# IT EXISTS SO A REFUSAL CAN NAME WHAT IT REFUSED. The decision belongs to
# `lcars_chunk_owner` below and to nothing else; this is only ever read to say
# *"it claims d77, and d77 is not an open seat"* instead of the much less useful
# *"nobody owns it"*. **Never branch an accept on this.**
lcars_chunk_claim() {
  local f mid line id owner
  f="$(lcars_chunk_owners_file "${1:-}")"
  mid="${2:-}"
  [ -n "$mid" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] || return 0
  id=""
  while IFS=$'\t' read -r line owner || [ -n "${line:-}" ]; do
    [ "$line" = "$mid" ] || continue
    id="${owner:-}"
  done <"$f"
  [ -n "$id" ] || return 0
  printf '%s' "$id"
}

# lcars_chunk_owner <lcars-dir> <mission-id> → the owning delegate id, or
# nothing at all.
#
# THIS IS THE ONE ADJUDICATOR, AND THAT IS THE WHOLE POINT OF THE FILE.
# S365 fix round 2 (F1). The library was shared and the ADJUDICATION was not:
# this function tested a line plus `delegates/<id>/BRIEF.md`, while
# `lcars-ech land` ALSO consulted the delegate record through python. So the two
# gates could disagree, and a fresh tester reached the disagreement with two
# DOCUMENTED verbs: `lcars-ech init --force` drops `delegates` by design, leaves
# the briefs by design, and did not touch `chunk-owners` — after which `land`
# blocked and **`approve` MERGED**. A shared reader with two adjudicators is the
# defect this file's header claimed to prevent.
#
# SO THE WHOLE TEST IS TWO `[ -f ]`s AND NO JSON AT ALL — no python in
# `approve.sh`, nothing to parse, nothing either caller can read differently:
#
#   * `delegates/<id>/BRIEF.md` — the artifact a MINT produces. One line in a
#     text file is the cheapest possible forgery of an accept; this raises the
#     bar to "a sub-ECH was really minted here".
#   * `delegates/<id>/OPEN` — the SEAT marker, written by `delegate` at mint and
#     removed by `delegate close` and by `init --force`. "Is this seat still
#     open" was a field in `autopilot.json` that only one of the two callers
#     could read; it is a file both of them can.
#
# WHEN IN DOUBT IT RETURNS NOTHING, which means the bug BLOCKS — the safe
# direction, every time, including on a seat minted before the marker existed.
lcars_chunk_owner() {
  local dir id
  dir="${1%/}"
  id="$(lcars_chunk_claim "$@")"
  [ -n "$id" ] || return 0
  [ -f "$dir/delegates/$id/BRIEF.md" ] || return 0
  [ -f "$dir/delegates/$id/OPEN" ] || return 0
  printf '%s' "$id"
}

# lcars_chunk_seat_open <lcars-dir> <delegate-id> — is that seat open? The same
# two files, so "open" means one thing on every surface that asks.
lcars_chunk_seat_open() {
  local dir="${1%/}" id="${2:-}"
  [ -n "$id" ] || return 1
  [ -f "$dir/delegates/$id/BRIEF.md" ] || return 1
  [ -f "$dir/delegates/$id/OPEN" ] || return 1
  return 0
}

# lcars_chunk_seat_open_mark / _clear <lcars-dir> <delegate-id> — the ONLY two
# writers of the seat marker. `delegate` marks, `delegate close` and
# `init --force` clear.
lcars_chunk_seat_open_mark() {
  local dir="${1%/}" id="${2:-}"
  [ -n "$id" ] || return 1
  mkdir -p "$dir/delegates/$id" || return 1
  : >"$dir/delegates/$id/OPEN" || return 1
  return 0
}
lcars_chunk_seat_open_clear() {
  local dir="${1%/}" id="${2:-}"
  [ -n "$id" ] || return 1
  rm -f "$dir/delegates/$id/OPEN"
  return 0
}

# lcars_chunk_own <lcars-dir> <mission-id> <delegate-id> — record it.
lcars_chunk_own() {
  local f dir bug did
  dir="${1:-}"; bug="${2:-}"; did="${3:-}"
  [ -n "$dir" ] && [ -n "$bug" ] && [ -n "$did" ] || return 1
  [ -d "$dir" ] || return 1
  f="$(lcars_chunk_owners_file "$dir")"
  printf '%s\t%s\n' "$bug" "$did" >>"$f" || return 1
  return 0
}

# lcars_chunk_release <lcars-dir> <delegate-id> — drop every line that delegate
# owns: EVERYTHING, the Missions it filed for its chunk as well as the bugs it
# was driving. Called when a sub-ECH is CLOSED: a closed sub-ECH drives nothing,
# and a claim that outlives the seat is exactly the stale claim that would buy a
# false accept. The Mission records themselves are untouched — the bugs go back
# to blocking, which is the correct state for a bug nobody is driving, and the
# Missions leave the closed seat's chunk.
lcars_chunk_release() {
  local f dir did tmp line owner
  dir="${1:-}"; did="${2:-}"
  [ -n "$dir" ] && [ -n "$did" ] || return 1
  f="$(lcars_chunk_owners_file "$dir")"
  [ -f "$f" ] || return 0
  tmp="$f.tmp.$$"
  : >"$tmp" || return 1
  while IFS=$'\t' read -r line owner || [ -n "${line:-}" ]; do
    [ -n "${line:-}" ] || continue
    [ "${owner:-}" = "$did" ] && continue
    printf '%s\t%s\n' "$line" "${owner:-}" >>"$tmp"
  done <"$f"
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  return 0
}

# lcars_chunk_owned <lcars-dir> <delegate-id> → every Mission id it owns —
# the ones it filed for its chunk and the bugs it is driving. Named for what it
# returns: it was `..._owned_bugs` while a row could only ever be a bug, and a
# function whose name says "bugs" while it returns Missions too is the kind of
# label this project has been bitten by before.
lcars_chunk_owned() {
  local f line owner
  f="$(lcars_chunk_owners_file "${1:-}")"
  [ -n "${2:-}" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] || return 0
  while IFS=$'\t' read -r line owner || [ -n "${line:-}" ]; do
    [ "${owner:-}" = "$2" ] || continue
    printf '%s\n' "$line"
  done <"$f"
}
