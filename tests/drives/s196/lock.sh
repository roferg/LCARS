#!/usr/bin/env bash
# ===========================================================================
# S196 TESTER — A6: THE CLI LOCKS WHAT THE BOARD LOCKS.
# Real gh, a real issue really assigned on github.com. There is one account, so
# "someone else's mission" is produced the only honest way: the issue really is
# assigned to `roferg` and this laptop is told, through the product's own
# LCARS_GH_USER identity seam, that it is a different login.
# ===========================================================================
. "$(dirname "$0")/../s189/lib.sh"
OWN_SH="$LCARS_SRC/skills/lcars-run/ownership.sh"
PAUSE_SH="$LCARS_SRC/skills/lcars-pause/pause.sh"
RESOLVE_SH="$LCARS_SRC/skills/lcars-resolve-logs/resolve-logs.sh"
jparse() { if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; then ok "JSON parses: $2"; else bad "INVALID JSON: $2"; fi; }

DATE="${S196_DATE:-20260909}"
A="$(laptop A)"; reset_laptop "$A"; lcars_config "$A"
cat >"$WORK/prd.md" <<'EOF'
# Mission: S196 lock — someone else's mission

**Type:** feature
**Goal:** Prove the CLI refuses exactly what the board refuses.
**Acceptance Criteria:**
- it does the thing
**Out of Scope:**
- everything else
**Constraints:**
- No new runtime dependencies
EOF
( cd "$A" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T14:00:00Z bash "$FILE_SH" --prd "$WORK/prd.md" ) >"$WORK/f.out" 2>&1
MID="$(ls "$A/.git/lcars/missions" | head -1)"; MD="$A/.git/lcars/missions/$MID"
ISSUE="$(st_raw "$MD/state.json" githubIssue)"
note "mission $MID  issue #$ISSUE"
OTHER="not-the-captain"
REAL_OWNER="$(hostin "$A" issue-assignees "$ISSUE")"
note "GitHub says #$ISSUE is assigned to '$REAL_OWNER'; this laptop claims to be '$OTHER'"
[ "$REAL_OWNER" = roferg ] && ok "the forge really assigned it" || bad "issue not assigned"

ONELINE="assigned to $REAL_OWNER — reassign it to yourself on GitHub to take command"

hdr "THE SENTENCE — the board's server-side re-check, verbatim"
BOARD_LINE="$( cd "$A" && LCARS_GH_USER="$OTHER" LCARS_GH_BIN="$LCARS_GH_BIN" bash "$OWN_SH" lock-reason "$ISSUE" )"
note "ownership.sh lock-reason → '$BOARD_LINE'"
[ "$BOARD_LINE" = "$ONELINE" ] && ok "the shared lock line is what the board shells for" || bad "board line differs: '$BOARD_LINE'"
JS_LINE="$(grep -n 'reassign it to yourself on GitHub to take command' web/static/board.js | head -1)"
note "board.js: $JS_LINE"
printf '%s' "$BOARD_LINE" >"$WORK/board.line"

BEFORE_SHA="$(shasum "$MD/state.json" | awk '{print $1}')"
cp -R "$MD" "$WORK/mission-before"

check_refusal() { # <label> <outfile> <rc>
  local label="$1" f="$2" rc="$3" n
  if [ "$rc" = 0 ]; then bad "$label: rc=0 — NOT refused"; sed 's/^/      /' "$f" | head -6; return; fi
  if grep -qF "$ONELINE" "$f"; then
    n=$(grep -cF "reassign it to yourself" "$f")
    ok "$label: refused (rc=$rc) with the plain line"
    [ "$n" = 1 ] && ok "$label: the line appears exactly ONCE" || bad "$label: line appears $n times"
    # BYTE identity against the board's own answer
    grep -oF "$ONELINE" "$f" | head -1 >"$WORK/cli.line.raw"
    if cmp -s <(printf '%s' "$ONELINE") <(tr -d '\n' <"$WORK/cli.line.raw"); then ok "$label: BYTE-IDENTICAL to the board's sentence"; else bad "$label: sentence differs from the board's"; fi
  else
    bad "$label: refused (rc=$rc) but not with the ownership line"; sed 's/^/      /' "$f" | head -8
  fi
}

hdr "THE THREE VERBS S196 ADDED"
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$PAUSE_SH" pause "$MID" ) >"$WORK/w.pause" 2>&1; check_refusal "lcars pause" "$WORK/w.pause" $?
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$PAUSE_SH" resume "$MID" ) >"$WORK/w.resume" 2>&1; check_refusal "lcars resume" "$WORK/w.resume" $?
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$RESOLVE_SH" "$MID" ) >"$WORK/w.rl" 2>&1; check_refusal "lcars resolve-logs" "$WORK/w.rl" $?

hdr "THE FIVE THAT ALREADY HAD IT (regression)"
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$APPROVE_SH" --mission "$MID" ) >"$WORK/w.approve" 2>&1; check_refusal "lcars approve" "$WORK/w.approve" $?
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$FEEDBACK_SH" --mission "$MID" --feedback "no" ) >"$WORK/w.feedback" 2>&1; check_refusal "lcars feedback" "$WORK/w.feedback" $?
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$RESPOND_SH" answer --mission "$MID" --answer "no" ) >"$WORK/w.respond" 2>&1; check_refusal "lcars respond answer" "$WORK/w.respond" $?
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$RUN_SH" drive --mission "$MID" --step ) >"$WORK/w.run" 2>&1; check_refusal "lcars run drive" "$WORK/w.run" $?
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$LOG_SH" "a bug against $MID" ) >"$WORK/w.log" 2>&1; check_refusal "lcars log" "$WORK/w.log" $?

hdr "NOTHING MOVED ON DISK"
AFTER_SHA="$(shasum "$MD/state.json" | awk '{print $1}')"
[ "$BEFORE_SHA" = "$AFTER_SHA" ] && ok "state.json byte-identical after eight refusals" || { bad "state.json changed"; diff "$WORK/mission-before/state.json" "$MD/state.json" | sed 's/^/      /'; }
diff -rq "$WORK/mission-before" "$MD" >/dev/null 2>&1 && ok "the whole mission dir is unchanged" || { bad "mission dir changed"; diff -rq "$WORK/mission-before" "$MD" | sed 's/^/      /'; }
jparse "$MD/state.json" "mission after the refusals"
LBL="$(hostin "$A" issue-labels "$ISSUE" 2>/dev/null | tr '\n' ' ')"
note "labels on #$ISSUE: $LBL"
case "$LBL" in *paused*) bad "a refused pause still applied lcars:paused on the forge" ;; *) ok "no lcars:paused label was applied on the forge" ;; esac

hdr "READS ARE NEVER BLOCKED"
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$STATUS_SH" ) >"$WORK/r.status" 2>&1; rc=$?
grep -q "$MID" "$WORK/r.status" && [ "$rc" = 0 ] && ok "lcars status lists it (rc=0)" || bad "status blocked (rc=$rc)"
grep -qi 'reassign it to yourself' "$WORK/r.status" && bad "status printed the lock line" || ok "status printed no lock line"
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$BUDDY_SH" ) >"$WORK/r.buddy" 2>&1; [ $? = 0 ] && ok "lcars buddy ran" || bad "buddy blocked"
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$RESPOND_SH" list ) >"$WORK/r.respondlist" 2>&1; [ $? = 0 ] && ok "lcars respond list ran" || bad "respond list blocked"

hdr "UNASSIGNED IS NEVER A LOCK"
hostin "$A" issue-unassign "$ISSUE" "$REAL_OWNER" >/dev/null 2>&1 || "$GH_REAL" issue edit "$ISSUE" -R "$FIXTURE" --remove-assignee "$REAL_OWNER" >/dev/null 2>&1
NOWN="$(hostin "$A" issue-assignees "$ISSUE")"
note "assignees now: '$NOWN'"
if [ -z "$NOWN" ]; then
  ok "the issue is genuinely unassigned on GitHub"
  rm -f "$A/.git/lcars/cache"/owner-* 2>/dev/null
  ( cd "$A" && LCARS_GH_USER="$OTHER" bash "$PAUSE_SH" pause "$MID" ) >"$WORK/u.pause" 2>&1; urc=$?
  note "pause on an UNASSIGNED mission rc=$urc"; sed 's/^/      /' "$WORK/u.pause" | head -4
  grep -qi 'reassign it to yourself' "$WORK/u.pause" && bad "unassigned was treated as a LOCK" || ok "unassigned is NOT a lock"
  ( cd "$A" && LCARS_GH_USER="$OTHER" bash "$PAUSE_SH" resume "$MID" ) >"$WORK/u.resume" 2>&1
  grep -qi 'reassign it to yourself' "$WORK/u.resume" && bad "unassigned locked resume" || ok "unassigned does not lock resume"
  jparse "$MD/state.json" "mission after the unassigned pause/resume"
else
  bad "could not unassign the issue — the unassigned leg is UNPROVEN"
fi

hdr "AN UNRESOLVABLE IDENTITY IS NEVER A LOCK"
"$GH_REAL" issue edit "$ISSUE" -R "$FIXTURE" --add-assignee "$REAL_OWNER" >/dev/null 2>&1
rm -f "$A/.git/lcars/cache"/owner-* 2>/dev/null
NOGH="$WORK/nogh"; mkdir -p "$NOGH"
printf '#!/usr/bin/env bash\nexit 127\n' >"$NOGH/gh"; chmod +x "$NOGH/gh"
( cd "$A" && env -u LCARS_GH_USER LCARS_GH_BIN="$NOGH/gh" bash "$PAUSE_SH" pause "$MID" ) >"$WORK/x.pause" 2>&1; xrc=$?
note "pause with an unreachable forge rc=$xrc"; sed 's/^/      /' "$WORK/x.pause" | head -4
grep -qi 'reassign it to yourself' "$WORK/x.pause" && bad "an unresolvable identity became a LOCK" || ok "unresolvable identity is NOT a lock"
jparse "$MD/state.json" "mission after the unreachable-forge pause"

hdr "TRY TO MAKE A LOCKED VERB ACT ANYWAY"
rm -f "$A/.git/lcars/cache"/owner-* 2>/dev/null
# 1. a PARTIAL id instead of the full one
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$PAUSE_SH" pause "${MID#lcars-}" ) >"$WORK/b.partial" 2>&1; brc=$?
[ "$brc" != 0 ] && grep -qF "$ONELINE" "$WORK/b.partial" && ok "a PARTIAL id is locked too" || { bad "partial id got past the lock (rc=$brc)"; sed 's/^/      /' "$WORK/b.partial" | head -4; }
# 2. resolve-logs `complete` — the other subcommand
( cd "$A" && LCARS_GH_USER="$OTHER" bash "$RESOLVE_SH" "$MID" complete ) >"$WORK/b.rlc" 2>&1; brc=$?
[ "$brc" != 0 ] && grep -qF "$ONELINE" "$WORK/b.rlc" && ok "resolve-logs complete is locked too" || { note "resolve-logs complete rc=$brc"; sed 's/^/      /' "$WORK/b.rlc" | head -4; }
# 3. the documented escape hatch — must still work, and be the ONLY one
( cd "$A" && LCARS_GH_USER="$OTHER" LCARS_OWNER_ENFORCE=0 bash "$PAUSE_SH" pause "$MID" ) >"$WORK/b.enforce0" 2>&1; brc=$?
[ "$brc" = 0 ] && ok "LCARS_OWNER_ENFORCE=0 is the documented bypass and still works" || bad "the documented bypass broke (rc=$brc)"
jparse "$MD/state.json" "mission after the deliberate bypass"
( cd "$A" && LCARS_GH_USER="$OTHER" LCARS_OWNER_ENFORCE=0 bash "$PAUSE_SH" resume "$MID" ) >"$WORK/b.enforce0r" 2>&1
jparse "$MD/state.json" "mission after the bypassed resume"

hdr "SPEND"; note "worker spawns: $(spawns)  billable: $(billable)  gh calls: $(gh_calls)"
printf '\n%d passed, %d failed\nWORK=%s\nMID=%s ISSUE=#%s\n' "$PASS" "$FAIL" "$WORK" "$MID" "$ISSUE"
[ "$FAIL" -eq 0 ]
