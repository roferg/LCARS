#!/usr/bin/env bash
# Shared pre-merge policy for approve and the host adapter.
# Callers supply MISSION_ID and MISSION_DIR; approve also supplies emit_event.

MERGE_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
merge_guard_approve_hint() {
  printf 'bash %q --mission %q' "$MERGE_GUARD_DIR/../lcars-approve/approve.sh" "$MISSION_ID"
}
merge_guard_resolve_hint() {
  printf 'bash %q --parent %q' "$MERGE_GUARD_DIR/../lcars-resolve-logs/resolve-logs.sh" "$MISSION_ID"
}

# --- WHICH SUB-ECH OWNS A LOGGED BUG (S365) --------------------------------
# THE SAME LIBRARY `lcars-eeh/ech.sh` READS, sourced here so this gate and the
# ECH's own accept pre-check cannot disagree about what a blocker is. That is
# the open-children gate's own rule applied once more: it and the folder use
# "deliberately the same reader … so the two can never disagree about what a
# child is".
#
# A MISSING LIBRARY DEGRADES, IT DOES NOT REFUSE — and the degradation is the
# SAFE direction: with no reader there are no owners, so every open logged bug
# blocks exactly as it did before S365. A broken install must never be able to
# buy an accept, and it must never take the merge gate down either.
LCARS_CHUNK_LIB="${LCARS_CHUNK_LIB:-$MERGE_GUARD_DIR/../lcars-eeh/chunk-owners.sh}"
if [ -f "$LCARS_CHUNK_LIB" ]; then
  # shellcheck source=../lcars-eeh/chunk-owners.sh
  . "$LCARS_CHUNK_LIB"
else
  lcars_chunk_owner() { return 0; }
fi

# S232 fix round 2 (D3): THE GATE'S OWN READER, ITS STDERR SILENCED.
# json_str is a `sed` call. On a `chmod 000` record sed writes
# `sed: …/state.json: Permission denied` to STDERR, and the captain was reading
# a tool's internal error sitting above the product's own refusal — which
# already names that exact file, so the noise carried nothing he did not have.
# This silences the READER only. The refusal and the warnings still go to stderr
# untouched, and every gate below reads through this, so what the gate can read
# stays identical to what json_str can read.
gate_json_str() {
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1
}

# open_logged_children [driven]
#   default  → "<id>\t<title>\t<stage>" per OPEN child THAT BLOCKS
#   "driven" → "<id>\t<title>\t<stage>\t<owner>" per open child a sub-ECH owns
# ONE reader, two views, so the list that blocks and the list that is let
# through can never be computed from two different definitions of a child. It
# is also why the second view is an ARGUMENT and not a global: this function is
# always called inside `$( )`, and a variable set in a command substitution
# never reaches its caller.
open_logged_children() {
  local cstate bid stage title folded missions_dir owner
  [ -n "${MISSION_DIR:-}" ] || return 0
  missions_dir="$(dirname "$MISSION_DIR")"
  for cstate in "$missions_dir"/*/state.json; do
    [ -f "$cstate" ] && [ -r "$cstate" ] || continue
    [ "$(gate_json_str "$cstate" parentMission)" = "$MISSION_ID" ] || continue
    [ "$(gate_json_str "$cstate" type)" = "bug" ] || continue
    stage="$(gate_json_str "$cstate" stage)"
    [ "$stage" = "done" ] && continue
    folded="$(gate_json_str "$cstate" foldedInto)"
    [ -n "$folded" ] && continue
    bid="$(gate_json_str "$cstate" id)"
    [ -n "$bid" ] || bid="$(basename "$(dirname "$cstate")")"
    title="$(gate_json_str "$cstate" title)"
    # S365 — A BUG A SUB-ECH OWNS AND IS DRIVING IS NOT AN OBSTACLE, exactly as
    # a `foldedInto` child above is not. THE GATE IS RIGHT AND ITS TIMING WAS
    # WRONG: measured on the 2026-11-18 capstone, four bugs filed through the
    # front door by the supervisor made the parent unacceptable until all four
    # reached their own Verify, so an ECH that filed bugs against a live Mission
    # had ended that Mission's run. An UNOWNED bug still blocks — that is the
    # half of this gate that is right, and it is the half a false accept would
    # destroy. NOT SILENT: every bug let through is named with its owner.
    owner="$(lcars_chunk_owner "$(dirname "$missions_dir")" "$bid")"
    if [ -n "$owner" ]; then
      [ "${1:-blockers}" = "driven" ] \
        && printf '%s\t%s\t%s\t%s\n' "$bid" "${title:-no title}" "${stage:-unknown}" "$owner"
      continue
    fi
    [ "${1:-blockers}" = "driven" ] && continue
    printf '%s\t%s\t%s\n' "$bid" "${title:-no title}" "${stage:-unknown}"
  done
}

# === S232 fix round 1 (D1): THE UNREADABLE RECORD — THE GATE'S BLIND SPOT ===
#
# The gate above opens with ONE line per candidate:
#
#     [ "$(json_str "$cstate" parentMission)" = "$MISSION_ID" ] || continue
#
# json_str is a sed reader, not a JSON parser. A state.json that is SCRAMBLED
# (`{ not json`) or BLANK yields EMPTY for every key, so that comparison fails
# and the child was SILENTLY skipped — a record that CANNOT BE READ was
# indistinguishable from a record that says "not a child of this Mission". The
# tester damaged only the child's state.json, three ways, and got 3 of 3 MERGED
# with no refusal and no warning of any kind. That is the one shape where the new
# gate was WORSE than nothing, because it was silent.
#
# WHY WE CANNOT JUST ATTRIBUTE IT. The parent↔child link is ONE-DIRECTIONAL:
# only the CHILD's state.json records `parentMission`; lcars-log writes nothing on
# the parent side and there is no loggedChildren list anywhere. So when a record
# cannot be read, the gate genuinely cannot tell whether it was a child of this
# Mission. A second linkage record would dissolve the ambiguity and is a bigger
# change than this; the answer here is to fail closed ON THE AMBIGUITY, which is
# the house precedent (init-mission.test.sh B5 — "an unreadable mission ordering
# REFUSES the waiver"). The cost is real and accepted: one broken record blocks
# approve for every mission in that repo. It is acceptable only because the
# refusal is LOUD and names the exact file, so the remedy is obvious.
#
# READABLE means readable BY THE GATE'S OWN READER — a non-empty `id` AND a
# non-empty `stage` via json_str. Deliberately the same reader `open_logged_children`
# uses, so the two can never disagree about what a record says: anything this
# accepts, that one can read.
#
# S232 fix round 2 (D1): AND "CANNOT BE READ" NOW INCLUDES "IS NOT A FILE".
# The loop used to open with `[ -f "$cstate" ] || continue`, which is FALSE both
# for a DIRECTORY named state.json and for a DANGLING SYMLINK — so both fell
# through to the lenient "mission directory with no state.json" warning and
# MERGED, and `mkdir .git/lcars/missions/<child>/state.json` was a deliberate
# bypass of this whole gate. That branch's rationale ("a mission directory exists
# before its state.json is written, so an interrupted filing leaves one") is
# simply false for both shapes: no interrupted filing produces either. `[ -e ]`
# and `[ -L ]` distinguish "something is there" from "nothing is there", so the
# rule the refusal already states — an unreadable record cannot be attributed
# either way — now covers every way a path can be there and unopenable. Only a
# GENUINELY ABSENT path keeps the lenient warning.
unreadable_mission_records() { # → one state.json path per record that cannot be read
  local cstate missions_dir
  [ -n "${MISSION_DIR:-}" ] || return 0
  missions_dir="$(dirname "$MISSION_DIR")"
  for cstate in "$missions_dir"/*/state.json; do
    # Nothing there at all — that is stateless_mission_dirs' lenient case, not
    # this one. `-L` is asked separately because `-e` is FALSE for a dangling
    # symlink, and a dangling symlink is very much "something is there".
    [ -e "$cstate" ] || [ -L "$cstate" ] || continue
    # Something IS there but cannot be opened and read as a regular file: a
    # directory, a dangling symlink, a chmod 000 record. Unattributable.
    if [ ! -f "$cstate" ] || [ ! -r "$cstate" ]; then
      printf '%s\n' "$cstate"; continue
    fi
    [ -n "$(gate_json_str "$cstate" id)" ] && [ -n "$(gate_json_str "$cstate" stage)" ] && continue
    printf '%s\n' "$cstate"
  done
}

# === S232 fix round 2 (D2): THE RECORD THAT LOST ONLY ITS PARENT LINK ========
#
# The second way a record is unattributable, and it was silent too. Take the
# record `lcars log` writes and remove ONLY `parentMission` / `parentIssue` /
# `origin`: still valid JSON, `id` and `stage` intact, so unreadable_mission_records
# accepts it — and with no `parentMission` it just fails open_logged_children's
# child test and is skipped. Nothing in the repo can attribute it, which is the
# exact condition the refusal above exists for, and the captain was told nothing.
#
# THE DISCRIMINATOR. A record whose `type` is `bug` MUST have a parent to be a
# logged bug: log.sh REQUIRES `**Type:** bug` (it dies otherwise) and always
# writes `parentMission` beside it. An ordinary mission legitimately has no
# parent, so `type: bug` is what keeps this from firing on every standalone
# mission in the repo. `stage = done` is excluded: a finished mission's fix is
# not owed to this PR, and that exclusion is what stops a repo full of old
# finished missions wedging approve months later.
#
# WHY A WARNING AND NOT A REFUSAL. `lcars file` ALSO accepts `**Type:** bug`
# (`case "$TYPE" in feature|bug)`) and writes NO `parentMission`, so a bug
# Mission filed standalone is a LEGITIMATE record of exactly this shape. A
# refusal would therefore block the one irreversible verb on a perfectly healthy
# repo — the cost we refuse to pay elsewhere in this gate. So this shape takes
# the same treatment the absent-record shape takes: named out loud, once,
# pre-merge, with what it means — never silent again, never a brick.
orphan_bug_records() { # → "<id>\t<title>\t<stage>" per bug record with NO parent link
  local cstate missions_dir stage bid title
  [ -n "${MISSION_DIR:-}" ] || return 0
  missions_dir="$(dirname "$MISSION_DIR")"
  for cstate in "$missions_dir"/*/state.json; do
    [ -f "$cstate" ] && [ -r "$cstate" ] || continue
    # Never the Mission being approved: a standalone bug Mission IS its own
    # record, and reporting it to itself is noise, not information.
    [ "$cstate" = "$MISSION_DIR/state.json" ] && continue
    [ "$(gate_json_str "$cstate" type)" = "bug" ] || continue
    [ -n "$(gate_json_str "$cstate" parentMission)" ] && continue
    stage="$(gate_json_str "$cstate" stage)"
    [ "$stage" = "done" ] && continue
    bid="$(gate_json_str "$cstate" id)"
    [ -n "$bid" ] || bid="$(basename "$(dirname "$cstate")")"
    title="$(gate_json_str "$cstate" title)"
    printf '%s\t%s\t%s\n' "$bid" "${title:-no title}" "${stage:-unknown}"
  done
}

# THE OTHER SHAPE, AND WHY IT IS *NOT* A REFUSAL.
#
# A mission DIRECTORY with no state.json at all is NOT treated as an obstacle,
# and that is a decision, not an oversight:
#   • it is a real transient. A mission directory is `mkdir`ed well BEFORE its
#     state.json is written (lcars-log/log.sh, and the same order in
#     lcars-file/file.sh), so an interrupted filing — or a partial `.git/lcars`
#     restore, the very route this defect describes — leaves one behind.
#   • it is invisible to EVERY other LCARS surface. status, respond, resolve-logs
#     and fold_logged_children all glob `*/state.json`, so no other verb thinks
#     that mission exists. Blocking approve alone would brick the one irreversible
#     verb over a record nothing else counts.
#   • there is nothing to name but the path: no id, no title, no stage, so a
#     refusal could not carry the four things the open-children refusal carries.
# But it is never SILENT again: it is WARNED about, by name, pre-merge. The
# tester's bar was "refuse, or at minimum say something"; for the unambiguously
# broken shape we refuse, and for the ambiguous one we say something.
stateless_mission_dirs() { # → one mission dir path per dir with NO state.json
  local mdir missions_dir
  [ -n "${MISSION_DIR:-}" ] || return 0
  missions_dir="$(dirname "$MISSION_DIR")"
  for mdir in "$missions_dir"/*/; do
    [ -d "$mdir" ] || continue
    mdir="${mdir%/}"
    # S232 fix round 2 (D1): GENUINELY ABSENT only. `-f` alone also let a
    # DIRECTORY named state.json and a DANGLING SYMLINK land in this lenient
    # branch, whose stated rationale (an interrupted filing) cannot produce
    # either. Anything that EXISTS there is unreadable_mission_records' problem.
    if [ -e "$mdir/state.json" ] || [ -L "$mdir/state.json" ]; then continue; fi
    printf '%s\n' "$mdir"
  done
}

# ONE plain paragraph, every child named (id, title, stage), one command that
# clears it, exit non-zero. Nothing merged, nothing reconciled, no label moved,
# no stage changed.
#
# S232 fix round 1 (D1): the unreadable-record branch comes FIRST and is its own
# paragraph. The open-children paragraph below is untouched — it keeps its four
# virtues (names the bug by title, its stage, the irreversibility, and ends
# "Nothing has been merged.").
refuse_if_open_logged_children() {
  local open bid title stage broken stateless rec sbid stitle sstage sowner
  broken="$(unreadable_mission_records)"
  if [ -n "$broken" ]; then
    {
      # S232 fix round 2 (D4): the old sentence ASSERTED whose record it was
      # ("cannot tell whether it is a logged bug of X") about a mission that may
      # never have had a logged bug in its life; the file path rescued him but
      # the sentence pointed the wrong way. This one RULES OUT instead, which is
      # all the gate actually knows. The paragraph's four virtues are unchanged:
      # it names the exact file(s), explains the irreversibility, gives the
      # remedy, and ends "Nothing has been merged." — plus one kindness, since
      # he is being told to "remove" a JSON file he has never opened.
      printf 'APPROVE: refused — a mission record in this repo cannot be read, so LCARS cannot rule out that it is a logged bug of %s still in flight. Only a child records its parent, so an unreadable record cannot be attributed either way, and merging is irreversible: once this Mission is Done its bugs cannot be folded onto it at all. Cannot be read:\n' \
        "$MISSION_ID"
      while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        printf '      • %s\n' "$rec"
      done <<<"$broken"
      printf 'Repair or remove each record above, then approve again. If one was a logged bug you no longer need, deleting its whole mission directory is safe — nothing else in LCARS refers to it. Nothing has been merged — run: %s\n' "$(merge_guard_approve_hint)"
    } >&2
    if declare -F emit_event >/dev/null; then
      emit_event approve_refused verify \
        "refused to merge — unreadable mission record(s): $(printf '%s' "$broken" | tr '\n' ' ') — run: $(merge_guard_approve_hint)"
    fi
    exit 1
  fi

  # Not an obstacle (see stateless_mission_dirs) — but said out loud, once. Both
  # call sites ask this gate, so STATELESS_WARNED is deliberately NOT local: it is
  # the once-flag that keeps the captain from reading the same warning twice and
  # concluding there are two broken directories.
  if [ -z "${STATELESS_WARNED:-}" ]; then
    stateless="$(stateless_mission_dirs)"
    if [ -n "$stateless" ]; then
      STATELESS_WARNED=1
      {
        printf '  ⚠ mission directory with no state.json — not blocking, but unattributable:\n'
        while IFS= read -r rec; do
          [ -n "$rec" ] || continue
          printf '      • %s\n' "$rec"
        done <<<"$stateless"
        printf '    A mission directory exists before its state.json is written, so an\n'
        printf '    interrupted filing leaves one, and no LCARS surface can see it. If one of\n'
        printf '    these WAS a logged bug of this Mission, its fix is NOT in this PR.\n'
      } >&2
    fi
  fi

  # S232 fix round 2 (D2): the other unattributable shape — a `type: bug` record
  # with NO parent link and not yet done. Warned, not refused (see
  # orphan_bug_records for why), and warned ONCE across both call sites, which is
  # why ORPHAN_WARNED is deliberately NOT local — same once-flag shape as
  # STATELESS_WARNED above, for the same reason.
  if [ -z "${ORPHAN_WARNED:-}" ]; then
    local orphans obid otitle ostage
    orphans="$(orphan_bug_records)"
    if [ -n "$orphans" ]; then
      ORPHAN_WARNED=1
      {
        printf '  ⚠ bug mission with no parent link — not blocking, but unattributable:\n'
        while IFS=$'\t' read -r obid otitle ostage; do
          [ -n "$obid" ] || continue
          printf '      • %s  %s  (stage %s)\n' "$obid" "$otitle" "$ostage"
        done <<<"$orphans"
        printf '    A logged bug always records the Mission it was logged against; this\n'
        printf '    record does not, so nothing can attribute it. If it WAS a logged bug of\n'
        printf '    this Mission, its fix is NOT in this PR. (A bug Mission you filed on its\n'
        printf '    own with `lcars file` reads this way too, and is fine.)\n'
      } >&2
    fi
  fi

  open="$(open_logged_children)"
  # SAID OUT LOUD, ONCE, WHETHER OR NOT ANYTHING BLOCKS. A bug this gate let
  # through is a bug somebody is still driving, and an accept that says nothing
  # about it is the silent drop this gate exists to prevent. Warned once across
  # both call sites, the same once-flag shape as the two warnings above.
  local driven; driven="$(open_logged_children driven)"
  if [ -n "$driven" ] && [ -z "${SUBECH_WARNED:-}" ]; then
    SUBECH_WARNED=1
    {
      printf '  ⚠ logged bug(s) a sub-ECH owns and is driving — NOT blocking this merge:\n'
      while IFS=$'\t' read -r sbid stitle sstage sowner; do
        [ -n "$sbid" ] || continue
        printf '      • %s  %s  (stage %s)  driven by sub-ECH %s\n' \
          "$sbid" "$stitle" "$sstage" "$sowner"
      done <<<"$driven"
      printf '    Authority travels with the chunk: the sub-ECH that owns each one takes it\n'
      printf '    the rest of the way. Its claim is recorded in .git/lcars/chunk-owners and it\n'
      printf '    BLOCKS again the moment nobody owns it (closing that sub-ECH releases it).\n'
    } >&2
  fi
  [ -n "$open" ] || return 0
  {
    printf 'APPROVE: refused — %s has logged bug(s) still open, and merging now would ship it with their fixes left outside the PR; once this Mission is Done its bugs cannot be folded onto it at all (a logged bug has no PR of its own, and resolve-logs only resolves an ACTIVE parent), so they would have to be re-filed by hand; still open: ' \
      "$MISSION_ID"
    while IFS=$'\t' read -r bid title stage; do
      [ -n "$bid" ] || continue
      printf '%s  %s  (stage %s); ' "$bid" "$title" "$stage"
    done <<<"$open"
    printf 'Nothing has been merged; take them the rest of the way with lcars resolve-logs %s — run: %s\n' \
      "$MISSION_ID" "$(merge_guard_resolve_hint)"
  } >&2
  if declare -F emit_event >/dev/null; then
    emit_event approve_refused verify \
      "refused to merge — logged bug(s) still open: $(printf '%s' "$open" | awk -F'\t' '{printf "%s (stage %s) ", $1, $3}') — run: $(merge_guard_resolve_hint)"
  fi
  exit 1
}
