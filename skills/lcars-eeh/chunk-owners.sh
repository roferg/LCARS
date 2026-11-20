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
#     .git/lcars/chunk-owners          <bug-mission-id>\t<delegate-id>
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

# lcars_chunk_owner <lcars-dir> <bug-mission-id> → the owning delegate id, or
# nothing at all. The LAST matching line wins, because the record is appended.
#
# AND A LINE ALONE IS NOT ENOUGH: the named delegate must also have the artifact
# a MINT produces — `delegates/<id>/BRIEF.md`. One line in a text file is the
# cheapest possible forgery of an accept, and this costs one `[ -f ]` to raise
# the bar to "a sub-ECH was really minted here". A mint never overwrites a
# brief and `init --force` deliberately leaves the brief files on disk, so a
# real owner always has one. WHEN IN DOUBT IT RETURNS NOTHING, which means the
# bug BLOCKS — the safe direction, every time. The ECH's own `land` goes further
# and checks the delegate RECORD itself; this is the half both readers can share.
lcars_chunk_owner() {
  local f bug line id dir owner
  dir="${1%/}"
  f="$(lcars_chunk_owners_file "${1:-}")"
  bug="${2:-}"
  [ -n "$bug" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] || return 0
  id=""
  while IFS=$'\t' read -r line owner || [ -n "${line:-}" ]; do
    [ "$line" = "$bug" ] || continue
    id="${owner:-}"
  done <"$f"
  [ -n "$id" ] || return 0
  [ -f "$dir/delegates/$id/BRIEF.md" ] || return 0
  printf '%s' "$id"
}

# lcars_chunk_own <lcars-dir> <bug-mission-id> <delegate-id> — record it.
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
# owns. Called when a sub-ECH is CLOSED: a closed sub-ECH drives nothing, and a
# claim that outlives the seat is exactly the stale claim that would buy a false
# accept. The bug Missions themselves are untouched — they go back to blocking,
# which is the correct state for a bug nobody is driving.
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

# lcars_chunk_owned_bugs <lcars-dir> <delegate-id> → the bug Missions it owns.
lcars_chunk_owned_bugs() {
  local f line owner
  f="$(lcars_chunk_owners_file "${1:-}")"
  [ -n "${2:-}" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] || return 0
  while IFS=$'\t' read -r line owner || [ -n "${line:-}" ]; do
    [ "${owner:-}" = "$2" ] || continue
    printf '%s\n' "$line"
  done <"$f"
}
