#!/usr/bin/env bash
# DRIVE 2 — THE LIGHT LOCK, ON A REAL ISSUE.
#
# Runs against the real mission ends-e2e.sh left on laptop B (issue assigned to
# the captain on real GitHub). There is only ONE real account, so "someone
# else's mission" is produced the only honest way available: the ISSUE really is
# assigned to `roferg`, and this laptop is told — through the product's own
# LCARS_GH_USER identity override — that it is a DIFFERENT login. Every
# assignee read is a real GitHub read.
#
# What must hold: READ verbs never blocked; WRITE verbs refuse with ONE plain
# line; LCARS_OWNER_ENFORCE=0 bypasses; an UNASSIGNED issue is never locked; an
# UNRESOLVABLE identity is never locked.
. "$(dirname "$0")/lib.sh"

ISSUE="$(cat "$S189_HOME/last-issue" 2>/dev/null)"
MID="$(cat "$S189_HOME/last-mid" 2>/dev/null)"
[ -n "$ISSUE" ] && [ -n "$MID" ] || { echo "run ends-e2e.sh first"; exit 1; }
B="$(laptop B)"; A="$(laptop A)"
BMDIR="$B/.git/lcars/missions/$MID"
[ -f "$BMDIR/state.json" ] || { echo "laptop B has no adopted mission — run ends-e2e.sh first"; exit 1; }
lcars_config "$B"
OTHER="not-the-captain"
REAL_OWNER="$(hostin "$B" issue-assignees "$ISSUE")"
hdr "PREMISE"
note "issue #$ISSUE really assigned to: '$REAL_OWNER'   this laptop claims to be: '$OTHER'"
[ "$REAL_OWNER" = roferg ] && ok "the forge says roferg owns it" || bad "issue is not assigned to roferg"

ONELINE='assigned to roferg — reassign it to yourself on GitHub to take command'

hdr "READ VERBS — must NEVER be blocked"
( cd "$B" && LCARS_GH_USER="$OTHER" bash "$STATUS_SH" ) >"$WORK/r.status" 2>&1
rc=$?; grep -q "$MID" "$WORK/r.status" && [ "$rc" = 0 ] \
  && ok "lcars status still lists the mission (rc=$rc)" || { bad "status blocked/rc=$rc"; sed 's/^/    /' "$WORK/r.status"; }
grep -qi 'reassign it to yourself' "$WORK/r.status" && bad "status printed the lock line" || ok "status printed no lock line"

( cd "$B" && LCARS_GH_USER="$OTHER" bash "$BUDDY_SH" ) >"$WORK/r.buddy" 2>&1
rc=$?; [ "$rc" = 0 ] && ok "lcars buddy ran (rc=0)" || bad "buddy rc=$rc"
grep -q "$MID" "$WORK/r.buddy" && ok "buddy still sees the mission" || note "buddy output did not name the mission (check by hand)"

( cd "$B" && LCARS_GH_USER="$OTHER" bash "$RESPOND_SH" list ) >"$WORK/r.respondlist" 2>&1
rc=$?; [ "$rc" = 0 ] && ok "lcars respond (list — a READ) ran (rc=0)" || bad "respond list rc=$rc"
grep -qi 'reassign it to yourself' "$WORK/r.respondlist" && bad "respond list printed the lock line" || ok "respond list not locked"

hdr "WRITE VERBS — must refuse with ONE plain line"
check_refusal() { # label  outfile  rc
  local label="$1" f="$2" rc="$3"
  if [ "$rc" = 0 ]; then bad "$label: rc=0 — it was NOT refused"; sed 's/^/    /' "$f" | head -6; return; fi
  if grep -qF "$ONELINE" "$f"; then
    local n; n=$(grep -cF "reassign it to yourself" "$f")
    ok "$label: refused with the plain line (rc=$rc)"
    [ "$n" = 1 ] && ok "$label: the line appears exactly once" || bad "$label: line appears $n times"
    note "$(grep -F "$ONELINE" "$f" | head -1)"
  else
    bad "$label: refused (rc=$rc) but not with the ownership line"; sed 's/^/    /' "$f" | head -6
  fi
}

( cd "$B" && LCARS_GH_USER="$OTHER" bash "$APPROVE_SH" --mission "$MID" ) >"$WORK/w.approve" 2>&1
check_refusal "approve" "$WORK/w.approve" $?
( cd "$B" && LCARS_GH_USER="$OTHER" bash "$FEEDBACK_SH" --mission "$MID" --feedback "not mine to bounce" ) >"$WORK/w.feedback" 2>&1
check_refusal "feedback" "$WORK/w.feedback" $?
( cd "$B" && LCARS_GH_USER="$OTHER" bash "$RESPOND_SH" answer --mission "$MID" --answer "not mine to answer" ) >"$WORK/w.respond" 2>&1
check_refusal "respond answer" "$WORK/w.respond" $?
( cd "$B" && LCARS_GH_USER="$OTHER" bash "$RUN_SH" drive --mission "$MID" ) >"$WORK/w.run" 2>&1
check_refusal "run drive" "$WORK/w.run" $?
printf '# Mission: a bug\n\n**Type:** bug\n**Goal:** g\n**Acceptance Criteria:**\n- a\n' >"$WORK/bug.md"
( cd "$B" && LCARS_GH_USER="$OTHER" bash "$LOG_SH" --parent "$MID" --prd "$WORK/bug.md" ) >"$WORK/w.log" 2>&1
check_refusal "log" "$WORK/w.log" $?

hdr "NO TRACE — a refusal must not have written anything"
[ -f "$BMDIR/feedback.md" ] && bad "feedback.md was created by a refused bounce" || ok "no feedback.md"
grep -q '"stage"[[:space:]]*:[[:space:]]*"verify"' "$BMDIR/state.json" && ok "stage untouched (verify)" || bad "stage changed"
n_open="$("$GH_REAL" issue list -R "$FIXTURE" --state open --json number --jq 'length')"
note "open issues on the fixture right now: $n_open (a refused \`log\` must not have opened one)"

hdr "LCARS_OWNER_ENFORCE=0 BYPASSES"
# Proved with `respond answer`, NOT with `feedback`: a bounce CLOSES the real PR
# on GitHub, and this drive must leave the fixture as it found it.
( cd "$B" && LCARS_GH_USER="$OTHER" LCARS_OWNER_ENFORCE=0 bash "$RESPOND_SH" answer --mission "$MID" --answer "__probe__" ) >"$WORK/b.respond" 2>&1
rc=$?
grep -qF "$ONELINE" "$WORK/b.respond" && bad "the bypass did not bypass" || ok "with ENFORCE=0 the lock did not fire (rc=$rc)"
sed 's/^/    /' "$WORK/b.respond" | head -6

hdr "AN UNRESOLVABLE IDENTITY IS NEVER A LOCK"
# gh gone from PATH entirely: whoami cannot answer, so nothing may be refused.
( cd "$B" && LCARS_GH_BIN=/nonexistent/gh LCARS_OWNER_CACHE_DIR="$WORK/nocache" bash "$APPROVE_SH" --mission "$MID" ) >"$WORK/u.approve" 2>&1
rc=$?
grep -qF "$ONELINE" "$WORK/u.approve" && bad "an unreachable forge LOCKED the captain out" || ok "unreachable forge → no ownership refusal (rc=$rc)"
note "$(head -3 "$WORK/u.approve" | tr '\n' ' ')"

hdr "AN UNASSIGNED MISSION IS NEVER A LOCK"
hostin "$B" issue-unassign "$ISSUE" roferg >/dev/null 2>&1
note "assignees now: '$(hostin "$B" issue-assignees "$ISSUE")'"
( cd "$B" && LCARS_GH_USER="$OTHER" bash "$RESPOND_SH" answer --mission "$MID" --answer "__probe2__" ) >"$WORK/n.respond" 2>&1
rc=$?
grep -qF "reassign it to yourself" "$WORK/n.respond" && bad "an UNASSIGNED mission was locked" || ok "unassigned → not locked (rc=$rc)"
note "$(head -2 "$WORK/n.respond" | tr '\n' ' ')"
hostin "$B" issue-assign "$ISSUE" roferg >/dev/null 2>&1
note "assignee restored: '$(hostin "$B" issue-assignees "$ISSUE")'"

hdr "SPEND"; note "worker spawns: $(spawns)   billable(--model): $(billable)   gh calls: $(gh_calls)"
printf '\n%d passed, %d failed\nWORK=%s\n' "$PASS" "$FAIL" "$WORK"
