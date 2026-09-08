#!/usr/bin/env bash
# DRIVE 3 — the dedup marker, temp-file hygiene, and destructive edges.
. "$(dirname "$0")/lib.sh"

mkmission() { # → repo path, mission at align WITH feedback.md (a bounced mission)
  local R; R="$(new_repo)"; write_prd "$R/prd-in.md"; write_adr "$R/adr-in.md"
  ( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R/prd-in.md" --adr "$R/adr-in.md" ) >/dev/null 2>&1
  printf '## Feedback — 2026-09-07T12:00:00Z (from verify)\n\nplease fix X.\n\n' \
     >"$R/.git/lcars/missions/lcars-20260907-001/feedback.md"
  printf '%s' "$R"
}
regrill() { printf '# Mission: Rewritten %s\n\n**Type:** feature\n**Goal:** g%s\n**Acceptance Criteria:**\n- a\n**Out of Scope:**\n- b\n**Constraints:**\n- c\n' "$2" "$2" >"$1/prd.md"; }

hdr "E1 — the marker is written only on a SUCCESSFUL push"
R="$(mkmission)"; M="$R/.git/lcars/missions/lcars-20260907-001"
regrill "$M" one
( cd "$R" && LCARS_STUB_EDIT_RC=1 bash "$RUN_SH" research --mission lcars-20260907-001 ) >/dev/null 2>&1
[ -f "$M/.issue-body.sha" ] && bad "a FAILED push wrote the marker" || ok "a failed push wrote NO marker"
note "mission dir after failed push: $(ls -a "$M" | tr '\n' ' ')"
ls "$M"/.issue-body.?????? >/dev/null 2>&1 && bad "LEAKED .issue-body.XXXXXX temp in the mission dir" || ok "no leaked mktemp body in the mission dir"
E=$(body_edits); note "edits attempted: $E"

hdr "E1b — the next transfer point RETRIES (self-healing)"
( cd "$R" && bash "$RUN_SH" research --mission lcars-20260907-001 ) >/dev/null 2>&1
[ -f "$M/.issue-body.sha" ] && ok "retry succeeded and recorded the marker: $(cat "$M/.issue-body.sha")" || bad "no retry"
E2=$(body_edits); [ "$E2" -gt "$E" ] && ok "the retry actually pushed" || bad "no retry push"

hdr "E2 — a HAND-EDITED / CORRUPT .issue-body.sha"
printf 'garbage-not-a-cksum\n' >"$M/.issue-body.sha"
( cd "$R" && bash "$RUN_SH" research --mission lcars-20260907-001 ) >/dev/null 2>&1
E3=$(body_edits); [ "$E3" -gt "$E2" ] && ok "a corrupt marker forces a re-push (fails safe)" || bad "a corrupt marker SUPPRESSED a push"

hdr "E3 — THE DANGEROUS ONE: a marker that matches, but GitHub's body is different"
# The marker is purely LOCAL. If anyone (a human on github.com, another laptop,
# a failed partial write) changes the issue body, this repo still believes it is
# current and pushes NOTHING. Simulated: the marker is current; nothing changes.
before=$(body_edits)
( cd "$R" && bash "$RUN_SH" research --mission lcars-20260907-001 ) >/dev/null 2>&1
after=$(body_edits)
if [ "$after" = "$before" ]; then
  note "as designed, an unchanged local body pushes nothing ($before → $after)."
  note "→ LEDGER: the dedup truth is LOCAL-ONLY. A body edited on github.com (or"
  note "  pushed by a second laptop) is NEVER repaired by a transfer point on this"
  note "  laptop, because .issue-body.sha still matches. Deleting .git/lcars is the"
  note "  only reset."
fi

hdr "E4 — the .issue-body.* glob: does anything now pick up .issue-body.sha?"
grep -rn '\.issue-body' "$LCARS_SRC/skills" "$LCARS_SRC/web" 2>/dev/null | sed 's/^/    /'

hdr "E5 — an EMPTY prd.md at the transfer point"
R2="$(mkmission)"; M2="$R2/.git/lcars/missions/lcars-20260907-001"
: >"$M2/prd.md"
b4=$(body_edits)
( cd "$R2" && bash "$RUN_SH" research --mission lcars-20260907-001 ) >"$WORK/e5.out" 2>&1
af=$(body_edits)
if [ "$af" -gt "$b4" ]; then
  last="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
  bad "an EMPTY prd.md was PUSHED — the issue body is now just the envelope"
  echo "      pushed body ($(wc -c <"$last") bytes):"; sed 's/^/      | /' "$last"
else ok "an empty prd.md pushed nothing"; fi

hdr "E6 — temp-file hygiene when gh CREATE fails on the filing lanes"
R3="$(new_repo)"; write_prd "$R3/prd-in.md"
( cd "$R3" && LCARS_STUB_CREATE_RC=1 LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R3/prd-in.md" ) >"$WORK/e6.out" 2>&1
M3="$R3/.git/lcars/missions/lcars-20260907-001"
note "mission dir: $(ls -a "$M3" 2>/dev/null | tr '\n' ' ')"
ls "$M3"/.issue-body.?????? >/dev/null 2>&1 && bad "grill-first lane LEAKED a .issue-body.XXXXXX on gh failure" || ok "grill-first lane leaked nothing on gh failure"

hdr "E6b — park lane, gh create fails"
R4="$(new_repo)"
( cd "$R4" && LCARS_STUB_CREATE_RC=1 LCARS_DATE=20260907 bash "$FILE_SH" --park "an idea" ) >"$WORK/e6b.out" 2>&1
M4="$R4/.git/lcars/missions/lcars-20260907-001"
note "mission dir: $(ls -a "$M4" 2>/dev/null | tr '\n' ' ')"
ls "$M4"/.issue-body.?????? >/dev/null 2>&1 && bad "PARK lane LEAKED a .issue-body.XXXXXX on gh failure" || ok "park lane leaked nothing on gh failure"

hdr "E6c — --complete lane, gh edit fails (mission stays PARKED)"
R5="$(new_repo)"; write_prd "$R5/prd-in.md"
( cd "$R5" && LCARS_DATE=20260907 bash "$FILE_SH" --park "an idea" ) >/dev/null 2>&1
( cd "$R5" && LCARS_STUB_EDIT_RC=1 bash "$FILE_SH" --complete lcars-20260907-001 --prd "$R5/prd-in.md" ) >"$WORK/e6c.out" 2>&1
M5="$R5/.git/lcars/missions/lcars-20260907-001"
note "mission dir: $(ls -a "$M5" 2>/dev/null | tr '\n' ' ')"
sed 's/^/    /' "$WORK/e6c.out" | tail -6
ls "$M5"/.issue-body.?????? >/dev/null 2>&1 && bad "--complete lane LEAKED a .issue-body.XXXXXX on gh failure" || ok "--complete lane leaked nothing on gh failure"

hdr "E7 — refresh on a mission with NO github issue (local-only)"
R6="$(mkmission)"; M6="$R6/.git/lcars/missions/lcars-20260907-001"
grep -v '"githubIssue"' "$M6/state.json" >"$M6/s.tmp" && mv "$M6/s.tmp" "$M6/state.json"
b=$(body_edits); ( cd "$R6" && bash "$RUN_SH" research --mission lcars-20260907-001 ) >/dev/null 2>&1
a=$(body_edits); [ "$a" = "$b" ] && ok "no issue → no push, no marker, no error" || bad "pushed without an issue"
[ -f "$M6/.issue-body.sha" ] && bad "marker written with no issue" || ok "no marker written"

hdr "SPEND"; note "worker spawns: $(spawns)  billable: $(billable)"
echo "WORK=$WORK"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
