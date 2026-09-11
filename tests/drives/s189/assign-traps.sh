#!/usr/bin/env bash
# DRIVE 3 — IDENTITY AND THE SILENT-DROP TRAP, against REAL GitHub.
#
# The spike's load-bearing finding: `gh issue edit --add-assignee <a real user
# who has no access to this private repo>` returns rc=0 WITH A SUCCESS-SHAPED
# URL and does not assign. If `issue-assign` believes that rc, LCARS records
# ownership GitHub refused — the exact bug the light lock exists to prevent,
# arriving through the lock itself. This drive fires that trap for real, with
# `octocat`, on the real private fixture repo.
. "$(dirname "$0")/lib.sh"

ISSUE="$(cat "$S189_HOME/last-issue" 2>/dev/null)"
[ -n "$ISSUE" ] || { echo "run ends-e2e.sh first"; exit 1; }
A="$(laptop A)"
ME="$(hostin "$A" whoami)"
hdr "PREMISE"
note "fixture: $FIXTURE (private)   issue: #$ISSUE   me: $ME"

hdr "1 — whoami"
[ "$ME" = roferg ] && ok "whoami → roferg" || bad "whoami → '$ME'"
grep -q 'gh api user' "$GH_LOG" && ok "it went through \`gh api user\` (the gh_api host-pinned wrapper)" \
  || note "no 'gh api user' in the log (a cache may have answered)"

hdr "2 — issue-assignees on an UNASSIGNED issue: EMPTY at rc=0, not an error"
hostin "$A" issue-unassign "$ISSUE" "$ME" >/dev/null 2>&1
out="$(hostin "$A" issue-assignees "$ISSUE")"; rc=$?
[ "$rc" = 0 ] && ok "rc=0" || bad "rc=$rc — an unassigned issue must not be an error"
[ -z "$out" ] && ok "printed nothing" || bad "printed '$out'"

hdr "3 — THE SILENT-DROP TRAP: assign a REAL login with no access to this private repo"
# `octocat` is a real GitHub account. It has no access to roferg/lcars-mp-fixture.
raw_out="$("$GH_REAL" issue edit "$ISSUE" -R "$FIXTURE" --add-assignee octocat 2>&1)"; raw_rc=$?
note "RAW gh: rc=$raw_rc out='$raw_out'"
[ "$raw_rc" = 0 ] && ok "confirmed: raw gh returns rc=0 with a success-shaped URL (the trap is live)" \
  || note "raw gh returned rc=$raw_rc — the trap did not fire on this account/repo today"
after_raw="$(hostin "$A" issue-assignees "$ISSUE")"
[ -z "$after_raw" ] && ok "…and GitHub did NOT assign octocat (assignees still empty)" \
  || bad "octocat really was assigned ('$after_raw') — this repo is not the trap fixture"

err="$(hostin "$A" issue-assign "$ISSUE" octocat 2>&1 >/dev/null)"; rc=$?
note "issue-assign rc=$rc"
note "message: $err"
[ "$rc" != 0 ] && ok "issue-assign FAILED (rc=$rc) rather than trusting gh's rc=0" \
  || bad "issue-assign returned 0 — it recorded ownership GitHub refused"
case "$err" in
  *"not assigned to octocat"*|*"cannot be assigned on this repo"*) ok "the message says the assignment did not stick" ;;
  *) bad "the message does not say the assignment did not stick" ;;
esac
case "$err" in
  *"does not exist"*|*"no such user"*|*"could not resolve to a user"*)
    bad "the message CLAIMS the login does not exist — nothing here can know that" ;;
  *) ok "the message does NOT claim the login does not exist" ;;
esac
after="$(hostin "$A" issue-assignees "$ISSUE")"
[ -z "$after" ] && ok "no ownership was recorded on the forge" || bad "assignees are now '$after'"

hdr "4 — a NONEXISTENT login fails LOUDLY (the spike's contrast case)"
err2="$(hostin "$A" issue-assign "$ISSUE" zz-no-such-login-s189-9182 2>&1 >/dev/null)"; rc2=$?
note "rc=$rc2  message: $(printf '%s' "$err2" | head -1)"
[ "$rc2" != 0 ] && ok "refused" || bad "a nonexistent login was accepted"

hdr "5 — lcars_claim_mission must NOT record a refused claim"
# The whole point: with the identity pinned to a login GitHub will not accept,
# the claim must WARN and return non-zero, and mission_owner must stay empty.
cat >"$WORK/claim-probe.sh" <<PROBE
#!/usr/bin/env bash
. "$LCARS_SRC/skills/lcars-run/ownership.sh"
w="\$(lcars_claim_mission "$ISSUE")" ; rc=\$?
printf 'CLAIM_RC=%s\n' "\$rc"
printf 'CLAIM_WARN=%s\n' "\$w"
unset _LCARS_OWNER_MEMO_$ISSUE
printf 'OWNER_AFTER=%s\n' "\$(mission_owner "$ISSUE")"
PROBE
( cd "$A" && LCARS_GH_USER=octocat LCARS_GH_BIN="$LCARS_GH_BIN" bash "$WORK/claim-probe.sh" ) >"$WORK/claim.out" 2>&1
sed 's/^/    /' "$WORK/claim.out"
grep -q '^CLAIM_RC=0$' "$WORK/claim.out" && bad "the claim reported SUCCESS for an assignment GitHub refused" \
  || ok "the claim returned non-zero"
grep -q '^CLAIM_WARN= *⚠' "$WORK/claim.out" && ok "it warned in one line" || bad "no warning line"
grep -q '^OWNER_AFTER=$' "$WORK/claim.out" && ok "mission_owner is still EMPTY — no false ownership" \
  || bad "mission_owner now reports an owner GitHub does not have"

hdr "6 — the honest round-trip: assign / read back / unassign"
hostin "$A" issue-assign "$ISSUE" "$ME" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "issue-assign $ME → rc=0" || bad "issue-assign $ME rc=$rc"
[ "$(hostin "$A" issue-assignees "$ISSUE")" = "$ME" ] && ok "GitHub shows $ME" || bad "GitHub does not show $ME"
hostin "$A" issue-assign "$ISSUE" "$ME" >/dev/null 2>&1
[ $? = 0 ] && ok "re-assigning the SAME login is an idempotent rc=0" || bad "re-assign was not idempotent"
hostin "$A" issue-unassign "$ISSUE" "$ME" >/dev/null 2>&1
[ "$(hostin "$A" issue-assignees "$ISSUE")" = "" ] && ok "issue-unassign removed it" || bad "unassign did not remove it"
hostin "$A" issue-unassign "$ISSUE" "$ME" >/dev/null 2>&1
[ $? = 0 ] && ok "unassigning a login that is NOT assigned is a silent rc=0 no-op" || bad "idempotent unassign failed"

hdr "7 — whoami degrades, never hangs"
cat >"$WORK/who-probe.sh" <<PROBE
#!/usr/bin/env bash
. "$LCARS_SRC/skills/lcars-run/ownership.sh"
v="\$(lcars_whoami)"; rc=\$?
printf 'WHOAMI=%s RC=%s\n' "\$v" "\$rc"
PROBE
( cd "$A" && LCARS_GH_USER=someone-pinned bash "$WORK/who-probe.sh" ) >"$WORK/who1" 2>&1
grep -q '^WHOAMI=someone-pinned RC=0$' "$WORK/who1" && ok "LCARS_GH_USER wins outright" || { bad "env override lost"; cat "$WORK/who1"; }
( cd "$A" && LCARS_GH_BIN=/nonexistent/gh LCARS_OWNER_CACHE_DIR="$WORK/cold" bash "$WORK/who-probe.sh" ) >"$WORK/who2" 2>&1 &
wpid=$!
( sleep 25; kill -9 $wpid 2>/dev/null ) & guard=$!
wait $wpid 2>/dev/null; kill $guard 2>/dev/null
grep -q '^WHOAMI= RC=1$' "$WORK/who2" && ok "gh absent → empty at rc=1, and it RETURNED (no hang)" || { bad "gh-absent whoami misbehaved"; cat "$WORK/who2"; }
( cd "$A" && LCARS_OWNER_CACHE_DIR="$WORK/warm" bash "$WORK/who-probe.sh" ) >/dev/null 2>&1
[ -f "$WORK/warm/whoami-github.com" ] && ok "the on-disk cache is HOST-SCOPED: $(ls "$WORK/warm")" || bad "no host-scoped cache file: $(ls "$WORK/warm" 2>/dev/null)"
n_before=$(grep -c 'gh api user' "$GH_LOG")
( cd "$A" && LCARS_OWNER_CACHE_DIR="$WORK/warm" bash "$WORK/who-probe.sh" ) >/dev/null 2>&1
n_after=$(grep -c 'gh api user' "$GH_LOG")
[ "$n_after" = "$n_before" ] && ok "a warm cache makes NO second \`gh api user\` call" || bad "the cache was not consulted ($((n_after-n_before)) extra calls)"

hdr "8 — LCARS_OWNER_ENFORCE=0 at the library level"
hostin "$A" issue-assign "$ISSUE" "$ME" >/dev/null 2>&1
cat >"$WORK/lock-probe.sh" <<PROBE
#!/usr/bin/env bash
. "$LCARS_SRC/skills/lcars-run/ownership.sh"
if r="\$(lcars_owner_lock_reason "$ISSUE")"; then printf 'LOCKED: %s\n' "\$r"; else printf 'NOT_LOCKED\n'; fi
PROBE
( cd "$A" && LCARS_GH_USER=not-the-captain bash "$WORK/lock-probe.sh" ) >"$WORK/l1" 2>&1
grep -q '^LOCKED: assigned to roferg' "$WORK/l1" && ok "locked for a stranger: $(cat "$WORK/l1")" || { bad "not locked"; cat "$WORK/l1"; }
( cd "$A" && LCARS_GH_USER=not-the-captain LCARS_OWNER_ENFORCE=0 bash "$WORK/lock-probe.sh" ) >"$WORK/l2" 2>&1
grep -q '^NOT_LOCKED$' "$WORK/l2" && ok "LCARS_OWNER_ENFORCE=0 bypasses the lock" || { bad "the bypass did not bypass"; cat "$WORK/l2"; }
( cd "$A" && LCARS_GH_USER="$ME" bash "$WORK/lock-probe.sh" ) >"$WORK/l3" 2>&1
grep -q '^NOT_LOCKED$' "$WORK/l3" && ok "the owner himself is never locked" || bad "the owner was locked"

hdr "SPEND"; note "worker spawns: $(spawns)   billable(--model): $(billable)   gh calls: $(gh_calls)"
printf '\n%d passed, %d failed\nWORK=%s\n' "$PASS" "$FAIL" "$WORK"
