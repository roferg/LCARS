#!/usr/bin/env bash
# ===========================================================================
# S196 TESTER — THE HEADLINE TEST, on real gh and two genuinely cold clones.
#
# The defect this session exists for: two laptops filing on the same day mint
# the IDENTICAL legacy mission id, and `lcars adopt` matched on that id,
# announced "refreshed an existing local mission", and OVERWROTE a SHIPPED
# mission in place — title, githubIssue, stage, and the whole merge record.
#
# LEGACY ids are minted here by the PRE-S196 PRODUCT ITSELF: a git worktree of
# this repo at 8b6faf8 (S191). That is exactly how the colliding ids on the
# captain's disk got there, and it is the compatibility case S196 promises to
# keep working. Nothing is hand-forged.
#
# ZERO MODEL SPEND — lib.sh's shims shadow both engines.
# ===========================================================================
. "$(dirname "$0")/../s189/lib.sh"

OLD_SRC="${S196_OLD_SRC:-/tmp/s196/LCARS-old}"
OLD_FILE_SH="$OLD_SRC/skills/lcars-file/file.sh"
[ -f "$OLD_FILE_SH" ] || { echo "no pre-S196 worktree at $OLD_SRC"; exit 77; }

jparse() { # <file> <label>  — the check S189's 100-check suite never made
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; then
    ok "JSON parses: $2"
  else
    bad "INVALID JSON: $2 ($1)"; sed 's/^/      /' "$1" | head -20
  fi
}

DATE="${S196_DATE:-20260909}"
A="$(laptop A)"; B="$(laptop B)"
reset_laptop "$A"; reset_laptop "$B"
lcars_config "$A"; lcars_config "$B"

mkprd() { cat >"$1" <<EOF
# Mission: $2

**Type:** feature
**Goal:** $3
**Acceptance Criteria:**
- it does the thing
- it keeps doing the thing
**Out of Scope:**
- everything else
**Constraints:**
- No new runtime dependencies
EOF
}

hdr "PREMISE — the PRE-S196 product mints the SAME id on two cold clones"
mkprd "$WORK/prdA.md" "S196 collision A — the SHIPPED mission" "A finance user exports invoices as CSV."
mkprd "$WORK/prdB.md" "S196 collision B — the newcomer" "A finance user filters the invoice list by month."
( cd "$A" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T10:00:00Z bash "$OLD_FILE_SH" --prd "$WORK/prdA.md" ) >"$WORK/fileA.out" 2>&1
( cd "$B" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T10:05:00Z bash "$OLD_FILE_SH" --prd "$WORK/prdB.md" ) >"$WORK/fileB.out" 2>&1
MID_A="$(ls "$A/.git/lcars/missions" 2>/dev/null | head -1)"
MID_B="$(ls "$B/.git/lcars/missions" 2>/dev/null | head -1)"
note "A minted: '$MID_A'   B minted: '$MID_B'"
[ -n "$MID_A" ] && [ -n "$MID_B" ] || { bad "one of the clones filed nothing"; sed 's/^/    /' "$WORK/fileA.out" "$WORK/fileB.out" | head -40; exit 1; }
[ "$MID_A" = "$MID_B" ] && ok "COLLISION IS REAL: both clones minted $MID_A (legacy shape, no fingerprint)" \
  || bad "no collision (A=$MID_A B=$MID_B) — the premise did not reproduce"
case "$MID_A" in lcars-$DATE-[0-9][0-9][0-9]) ok "legacy id shape, no fingerprint" ;; *) bad "unexpected id shape: $MID_A" ;; esac

AMDIR="$A/.git/lcars/missions/$MID_A"
BMDIR="$B/.git/lcars/missions/$MID_B"
ISSUE_A="$(st_raw "$AMDIR/state.json" githubIssue)"
ISSUE_B="$(st_raw "$BMDIR/state.json" githubIssue)"
note "issues: A=#$ISSUE_A  B=#$ISSUE_B"
echo "$ISSUE_A $ISSUE_B" >"$S189_HOME/s196-issues"
[ -n "$ISSUE_A" ] && [ -n "$ISSUE_B" ] && [ "$ISSUE_A" != "$ISSUE_B" ] || { bad "issues did not open"; exit 1; }

hdr "STEP 1 — laptop A SHIPS its mission (real branch, real PR, real merge)"
BRANCH_A="$(st_get "$AMDIR/state.json" branch)"
note "branch: $BRANCH_A"
fixture_drop_branch "$BRANCH_A"
( cd "$A" && { git checkout -q "$BRANCH_A" 2>/dev/null || git checkout -q -b "$BRANCH_A" main; } \
  && mkdir -p src && printf 'def export_csv(rows):\n    yield from rows\n' > src/export_s196.py \
  && git add -A && git commit -q -m "feat: stream the invoice CSV export" ) >/dev/null 2>&1
st_set_str "$AMDIR/state.json" stage verify
hostin "$A" issue-relabel "$ISSUE_A" --add "lcars:verify" --remove "lcars:align" >/dev/null 2>&1
( cd "$A" && bash "$RUN_SH" open-pr --mission "$MID_A" ) >"$WORK/openprA.out" 2>&1
sed 's/^/    /' "$WORK/openprA.out" | head -8
PRURL_A="$(st_get "$AMDIR/state.json" prUrl)"
case "$PRURL_A" in http*) ok "real PR open: $PRURL_A" ;; *) bad "no PR opened on A"; exit 1 ;; esac
( cd "$A" && bash "$APPROVE_SH" --mission "$MID_A" ) >"$WORK/approveA.out" 2>&1
note "approve rc=$?"; sed 's/^/    /' "$WORK/approveA.out" | head -12
jparse "$AMDIR/state.json" "A's shipped mission after approve"

SHIP_STAGE="$(st_get "$AMDIR/state.json" stage)"
SHIP_REVIEW="$(st_get "$AMDIR/state.json" review)"
SHIP_PRNUM="$(st_get "$AMDIR/state.json" prNumber)"; [ -n "$SHIP_PRNUM" ] || SHIP_PRNUM="$(st_raw "$AMDIR/state.json" prNumber)"
SHIP_TITLE="$(st_get "$AMDIR/state.json" title)"
note "SHIPPED RECORD → stage='$SHIP_STAGE' review='$SHIP_REVIEW' prNumber='$SHIP_PRNUM' prUrl='$PRURL_A' issue=$ISSUE_A"
note "title='$SHIP_TITLE'"
[ "$SHIP_REVIEW" = merged ] && ok "review=merged (a genuinely shipped mission)" || bad "review='$SHIP_REVIEW' — expected merged"
[ "$SHIP_STAGE" = done ] && ok "stage=done" || bad "stage='$SHIP_STAGE' — expected done"

BEFORE_SHA="$(shasum "$AMDIR/state.json" | awk '{print $1}')"
cp -R "$AMDIR" "$WORK/A-before"
note "state.json sha before adopt: $BEFORE_SHA"

hdr "STEP 2 — THE HEADLINE: laptop A adopts laptop B's issue #$ISSUE_B (colliding id $MID_A)"
( cd "$A" && bash "$ADOPT_SH" "$ISSUE_B" ) >"$WORK/adoptcollide.out" 2>&1
ARC=$?
note "adopt rc=$ARC"
sed 's/^/    /' "$WORK/adoptcollide.out"
cp "$WORK/adoptcollide.out" "$S189_HOME/s196-collision-refusal.txt"

hdr "STEP 3 — IS THE SHIPPED MISSION INTACT?"
AFTER_SHA="$(shasum "$AMDIR/state.json" | awk '{print $1}')"
[ "$BEFORE_SHA" = "$AFTER_SHA" ] && ok "state.json BYTE-IDENTICAL after adopt" \
  || { bad "state.json CHANGED — $BEFORE_SHA → $AFTER_SHA"; diff "$WORK/A-before/state.json" "$AMDIR/state.json" | sed 's/^/      /'; }
jparse "$AMDIR/state.json" "A's shipped mission after the colliding adopt"
for f in title stage review prUrl; do
  v="$(st_get "$AMDIR/state.json" "$f")"
  case "$f" in
    title)  [ "$v" = "$SHIP_TITLE" ]  && ok "title intact: '$v'"        || bad "title CLOBBERED: '$v' (was '$SHIP_TITLE')" ;;
    stage)  [ "$v" = "$SHIP_STAGE" ]  && ok "stage intact: '$v'"        || bad "stage CLOBBERED: '$v' (was '$SHIP_STAGE')" ;;
    review) [ "$v" = "$SHIP_REVIEW" ] && ok "review intact: '$v'"       || bad "review CLOBBERED: '$v' (was '$SHIP_REVIEW')" ;;
    prUrl)  [ "$v" = "$PRURL_A" ]     && ok "prUrl intact: '$v'"        || bad "prUrl CLOBBERED: '$v' (was '$PRURL_A')" ;;
  esac
done
NOW_ISSUE="$(st_raw "$AMDIR/state.json" githubIssue)"
[ "$NOW_ISSUE" = "$ISSUE_A" ] && ok "githubIssue intact: $NOW_ISSUE" || bad "githubIssue CLOBBERED: $NOW_ISSUE (was $ISSUE_A)"
NOW_PRNUM="$(st_get "$AMDIR/state.json" prNumber)"; [ -n "$NOW_PRNUM" ] || NOW_PRNUM="$(st_raw "$AMDIR/state.json" prNumber)"
[ "$NOW_PRNUM" = "$SHIP_PRNUM" ] && ok "prNumber intact: $NOW_PRNUM" || bad "prNumber CLOBBERED: $NOW_PRNUM (was $SHIP_PRNUM)"
if diff -rq "$WORK/A-before" "$AMDIR" >"$WORK/dirdiff.out" 2>&1; then
  ok "the ENTIRE mission directory is unchanged"
else
  bad "mission directory changed:"; sed 's/^/      /' "$WORK/dirdiff.out"
fi

hdr "STEP 4 — what did adopt actually DO?"
N_MISSIONS="$(ls "$A/.git/lcars/missions" 2>/dev/null | wc -l | tr -d ' ')"
note "missions on A now: $(ls "$A/.git/lcars/missions" | tr '\n' ' ')"
if [ "$ARC" -ne 0 ]; then
  ok "adopt REFUSED (rc=$ARC) rather than refreshing"
  [ "$N_MISSIONS" = 1 ] && ok "nothing was created (still 1 mission dir)" || bad "adopt refused but left $N_MISSIONS dirs"
  grep -qi "refresh" "$WORK/adoptcollide.out" && bad "the refusal still says 'refresh'" || ok "the word 'refresh' does not appear"
  grep -q "#$ISSUE_A" "$WORK/adoptcollide.out" && ok "the refusal names the mission it protected (#$ISSUE_A)" || bad "the refusal does not name #$ISSUE_A"
else
  note "adopt SUCCEEDED — then it must have made a SEPARATE mission"
  [ "$N_MISSIONS" = 2 ] && ok "two separate missions on A" || bad "adopt succeeded but there are $N_MISSIONS mission dirs"
fi
grep -qi "refreshed an existing local mission" "$WORK/adoptcollide.out" \
  && bad "THE ORIGINAL DEFECT SENTENCE IS BACK" || ok "no 'refreshed an existing local mission' claim"

hdr "STEP 5 — the branch on the shared remote was not stolen"
TIP_NOW="$(cd "$A" && git rev-parse "$BRANCH_A" 2>/dev/null)"
note "local $BRANCH_A tip: $TIP_NOW"
[ -n "$TIP_NOW" ] && ok "A still owns its branch locally" || bad "A's branch vanished"

hdr "STEP 6 — parse EVERY state.json on both clones"
for f in "$A"/.git/lcars/missions/*/state.json "$B"/.git/lcars/missions/*/state.json; do
  [ -f "$f" ] || continue
  jparse "$f" "$(basename "$(dirname "$f")") in $(basename "$(dirname "$(dirname "$(dirname "$(dirname "$f")")")")")"
done
for c in "$A" "$B"; do
  [ -f "$c/.git/lcars/config.json" ] && jparse "$c/.git/lcars/config.json" "config.json in $(basename "$c")"
done

hdr "SPEND"; note "worker spawns: $(spawns)  billable: $(billable)  gh calls: $(gh_calls)"
printf '\n%d passed, %d failed\nWORK=%s\nissues: A=#%s B=#%s\nMID=%s\n' "$PASS" "$FAIL" "$WORK" "$ISSUE_A" "$ISSUE_B" "$MID_A"
[ "$FAIL" -eq 0 ]
