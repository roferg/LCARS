#!/usr/bin/env bash
# DRIVE 1 — THE MAIN ROAD, ON REAL GITHUB.
#
# Laptop A files a real mission on roferg/lcars-mp-fixture, drives it to Verify
# (real branch pushed, real PR opened). Laptop B — a SECOND REAL CLONE with no
# `.git/lcars` at all — adopts it from the issue alone and must end up holding a
# mission that `lcars status` lists and `lcars approve` can act on.
#
# It STOPS AT THE RESOLUTION PROOF: a merge fuse intercepts `gh pr merge`,
# records its argv, and refuses. Nothing is ever merged.
. "$(dirname "$0")/lib.sh"

A="$(laptop A)"; B="$(laptop B)"
reset_laptop "$A"; reset_laptop "$B"
lcars_config "$A"           # laptop B is DELIBERATELY left uninitialised.

DATE=20260908
MID_EXPECT=""

hdr "STEP 1 — laptop A files a real mission"
cat >"$WORK/prd.md" <<'EOF'
# Mission: Add a CSV export to the invoice list

**Type:** feature
**Goal:** A finance user can download the current invoice list as a CSV from the list page, so month-end reconciliation stops being copy-paste out of the table.
**Acceptance Criteria:**
- An "Export CSV" button sits above the invoice table
- Clicking it downloads `invoices-<YYYY-MM-DD>.csv`
- The CSV carries the same rows and columns the table currently shows, in the same order
- The export respects the active filters
**Out of Scope:**
- XLSX or PDF export
**Constraints:**
- No new runtime dependencies
EOF
cat >"$WORK/adr.md" <<'EOF'
# ADR: Stream the CSV from the existing query

**Context:** The invoice list is already paginated off a single query builder.
**Decision:** Reuse that builder with a cursor and stream rows to the response.
**Alternatives considered:** Buffer the whole result set (rejected: 10k+ rows).
**Consequences:** No new deps; memory stays flat.
EOF
( cd "$A" && LCARS_DATE=$DATE LCARS_NOW=2026-09-08T10:00:00Z \
    bash "$FILE_SH" --prd "$WORK/prd.md" --adr "$WORK/adr.md" ) >"$WORK/file.out" 2>&1
sed 's/^/    /' "$WORK/file.out"
MID="$(ls "$A/.git/lcars/missions" 2>/dev/null | head -1)"
AMDIR="$A/.git/lcars/missions/$MID"
[ -n "$MID" ] && ok "filed: $MID" || { bad "filing produced no mission"; exit 1; }
ISSUE="$(st_raw "$AMDIR/state.json" githubIssue)"
[ -n "$ISSUE" ] && [ "$ISSUE" != null ] && ok "real issue #$ISSUE opened" || { bad "no real issue"; exit 1; }
echo "$ISSUE" >"$S189_HOME/last-issue"; echo "$MID" >"$S189_HOME/last-mid"

hdr "STEP 1b — filing ASSIGNED the mission to the captain (the S189 claim)"
ASSIGNEES="$(hostin "$A" issue-assignees "$ISSUE")"
note "issue-assignees #$ISSUE → '$ASSIGNEES'"
ME="$(hostin "$A" whoami)"
[ "$ASSIGNEES" = "$ME" ] && ok "GitHub really shows $ME as assignee (read back off the API, not off rc=0)" \
  || bad "assignee is '$ASSIGNEES', expected '$ME'"

hdr "STEP 2 — laptop A does the work and reaches Verify"
BRANCH="$(st_get "$AMDIR/state.json" branch)"
note "branch: $BRANCH"
fixture_drop_branch "$BRANCH"   # a previous run's remote head would block the push
( cd "$A" && { git checkout -q "$BRANCH" 2>/dev/null || git checkout -q -b "$BRANCH" main; } \
    && mkdir -p src && printf 'def export_csv(rows):\n    yield from rows\n' > src/export.py \
    && git add -A && git commit -q -m "feat: stream the invoice CSV export" ) >/dev/null 2>&1
( cd "$A" && git rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null ) \
  && ok "branch $BRANCH cut off main with one real commit" || bad "branch not created"
st_set_str "$AMDIR/state.json" stage verify
# The stage label is what the PIPELINE moves at every transition (gh_relabel) and
# the ONLY place adopt is allowed to read a stage from. Forcing the local stage
# without moving the label would leave the issue saying `align` — so move it here
# exactly as drive_implement→verify would.
hostin "$A" issue-relabel "$ISSUE" --add "lcars:verify" --remove "lcars:align" >/dev/null 2>&1
( cd "$A" && bash "$RUN_SH" open-pr --mission "$MID" ) >"$WORK/openpr.out" 2>&1
sed 's/^/    /' "$WORK/openpr.out"
PRURL_A="$(st_get "$AMDIR/state.json" prUrl)"
PRNUM_A="$(st_get "$AMDIR/state.json" prNumber)"
[ -n "$PRNUM_A" ] || PRNUM_A="$(st_raw "$AMDIR/state.json" prNumber)"
case "$PRURL_A" in
  http*) ok "real PR opened: $PRURL_A (#$PRNUM_A)"; echo "$PRNUM_A" >"$S189_HOME/last-pr" ;;
  *) bad "no PR opened"; exit 1 ;;
esac

hdr "STEP 3 — laptop B, before adopting: EMPTY"
[ -d "$B/.git/lcars" ] && bad "laptop B already has .git/lcars (the premise is broken)" \
  || ok "laptop B has NO .git/lcars at all"
( cd "$B" && bash "$STATUS_SH" ) >"$WORK/statusB0.out" 2>&1
note "status rc=$?"; sed 's/^/    /' "$WORK/statusB0.out" | head -8
grep -q "$MID" "$WORK/statusB0.out" && bad "status already lists $MID" || ok "status lists nothing"

hdr "STEP 4 — lcars adopt $ISSUE on laptop B"
( cd "$B" && bash "$ADOPT_SH" "$ISSUE" ) >"$WORK/adopt.out" 2>&1
ARC=$?
note "adopt rc=$ARC"; sed 's/^/    /' "$WORK/adopt.out"
BMDIR="$B/.git/lcars/missions/$MID"
[ -f "$BMDIR/state.json" ] && ok "mission rebuilt at $BMDIR (id REUSED, not minted)" \
  || { bad "no mission dir at $BMDIR"; note "what IS there: $(ls "$B/.git/lcars/missions" 2>/dev/null | tr '\n' ' ')"; }
n_missions="$(ls "$B/.git/lcars/missions" 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_missions" = 1 ] && ok "exactly one mission dir on B (no minted second id)" || bad "B has $n_missions mission dirs"

hdr "STEP 5 — DOES IT SHOW UP AT ALL? (the captain's first question)"
( cd "$B" && bash "$STATUS_SH" ) >"$WORK/statusB1.out" 2>&1
sed 's/^/    /' "$WORK/statusB1.out" | head -20
grep -q "$MID" "$WORK/statusB1.out" && ok "lcars status on laptop B LISTS the mission" || bad "status does not list $MID"

hdr "STEP 6 — every envelope-carried field, A vs B"
for f in id title stage branch base model workerBin type prUrl review; do
  av="$(st_get "$AMDIR/state.json" "$f")"; bv="$(st_get "$BMDIR/state.json" "$f")"
  if [ "$av" = "$bv" ]; then ok "$f: '$av' identical"
  else bad "$f: A='$av'  B='$bv'"; fi
done
for f in githubIssue; do
  av="$(st_raw "$AMDIR/state.json" "$f")"; bv="$(st_raw "$BMDIR/state.json" "$f")"
  if [ "$av" = "$bv" ]; then ok "$f: $av identical"; else bad "$f: A=$av  B=$bv"; fi
done
# prNumber is written as a JSON STRING by pr-lib.sh open_pr ("prNumber": "21")
# and as a JSON NUMBER by adopt.sh (state_set_raw). The VALUE matches; the TYPE
# does not, so the two laptops' state.json are not interchangeable to a real JSON
# reader. Both verbs that read it (approve.sh, run.sh drive_pr_merged) use the
# bare-token reader, which returns "" for the QUOTED form and silently falls back
# to `--head <branch>` — so it is latent today, not broken.
apn="$(st_get "$AMDIR/state.json" prNumber)"; [ -n "$apn" ] || apn="$(st_raw "$AMDIR/state.json" prNumber)"
bpn="$(st_get "$BMDIR/state.json" prNumber)"; [ -n "$bpn" ] || bpn="$(st_raw "$BMDIR/state.json" prNumber)"
[ "$apn" = "$bpn" ] && ok "prNumber VALUE matches ($apn)" || bad "prNumber value differs: A=$apn B=$bpn"
at=string; grep -q "\"prNumber\"[[:space:]]*:[[:space:]]*[0-9]" "$AMDIR/state.json" && at=number
bt=string; grep -q "\"prNumber\"[[:space:]]*:[[:space:]]*[0-9]" "$BMDIR/state.json" && bt=number
[ "$at" = "$bt" ] && ok "prNumber JSON TYPE matches ($at)" \
  || bad "prNumber JSON TYPE differs: A=$at (pr-lib state_set_str) B=$bt (adopt state_set_raw)"
note "A state: $(tr -d '\n' <"$AMDIR/state.json")"
note "B state: $(tr -d '\n' <"$BMDIR/state.json")"

hdr "STEP 6b — the branch came with it"
( cd "$B" && git rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null 2>&1 ) \
  && ok "laptop B has a local $BRANCH" || bad "laptop B has no local $BRANCH"
atip="$(cd "$A" && git rev-parse "$BRANCH")"; btip="$(cd "$B" && git rev-parse "$BRANCH" 2>/dev/null)"
[ "$atip" = "$btip" ] && ok "same tip commit ($atip)" || bad "tips differ: A=$atip B=$btip"
[ -f "$BMDIR/prd.md" ] && ok "prd.md rebuilt" || bad "no prd.md on B"
note "B prd.md first line: $(head -1 "$BMDIR/prd.md" 2>/dev/null)"
grep -q 'lcars:handoff' "$BMDIR/prd.md" 2>/dev/null && bad "the envelope leaked into prd.md" || ok "envelope stripped from prd.md"
# DOCUMENTED, not a defect: adopt rebuilds prd.md as the WHOLE body minus the
# envelope, so it is a SUPERSET of laptop A's prd.md (it also carries the ADR and
# the `## Estimate` section — nothing records where one ends and the next begins).
# Assert the superset relation rather than equality, so a future change that
# starts DROPPING spec text is caught.
if diff <(cat "$AMDIR/prd.md") <(head -n "$(wc -l <"$AMDIR/prd.md" | tr -d ' ')" "$BMDIR/prd.md") >/dev/null 2>&1; then
  ok "B's prd.md STARTS with A's prd.md byte-for-byte (superset, nothing lost)"
else
  bad "B's prd.md does not start with A's prd.md"
  diff "$AMDIR/prd.md" "$BMDIR/prd.md" | head -10 | sed 's/^/    /'
fi
note "A prd.md: $(wc -l <"$AMDIR/prd.md" | tr -d ' ') lines   B prd.md: $(wc -l <"$BMDIR/prd.md" | tr -d ' ') lines (the extra is the ADR + ## Estimate the composed body carries)"

hdr "STEP 7 — lcars approve on laptop B RESOLVES the real PR (merge fused OFF)"
# The fuse: everything passes through to real gh EXCEPT `pr merge`, which is
# recorded and refused. NOTHING IS MERGED.
MERGELOG="$WORK/merge.log"; : >"$MERGELOG"
cat >"$WORK/gh-nomerge" <<FUSE
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"$GH_LOG"
if [ "\${1:-}" = pr ] && [ "\${2:-}" = merge ]; then
  printf 'MERGE-ATTEMPT\t%s\n' "\$*" >>"$MERGELOG"
  echo "s189 tester: merge fuse — refusing to merge the fixture PR" >&2
  exit 1
fi
exec "$GH_REAL" "\$@"
FUSE
chmod +x "$WORK/gh-nomerge"
( cd "$B" && LCARS_GH_BIN="$WORK/gh-nomerge" LCARS_MERGE_RETRIES=1 LCARS_MERGE_RETRY_SLEEP=0 \
    bash "$APPROVE_SH" --mission "$MID" ) >"$WORK/approve.out" 2>&1
note "approve rc=$?"; sed 's/^/    /' "$WORK/approve.out" | head -25
if [ -s "$MERGELOG" ]; then
  note "$(cat "$MERGELOG")"
  # The adapter turns `--number N` into `gh pr merge N --merge` and `--head B`
  # into `gh pr merge B --merge`, so assert on the SELECTOR gh actually
  # received, not on approve's internal flag.
  #
  # S189 fix round 2: adopt now writes prNumber as a JSON STRING (cure 2,
  # matching pr-lib.sh:217), so approve's BARE-TOKEN reader returns "" and it
  # takes the documented `--head <branch>` fallback. EITHER selector is correct;
  # what matters is that the selector RESOLVES THE REAL PR — so accept both and
  # then prove the resolution against GitHub.
  SEL="$(sed -n 's/^MERGE-ATTEMPT	pr merge \([^ ]*\).*/\1/p' "$MERGELOG" | head -1)"
  note "merge selector gh received: '$SEL'"
  case "$SEL" in
    "$PRNUM_A") ok "selector is the recorded PR NUMBER #$PRNUM_A" ;;
    "$BRANCH")  ok "selector is the branch $BRANCH (the --head fallback cure 2 forces)" ;;
    *) bad "merge selector '$SEL' is neither PR #$PRNUM_A nor branch $BRANCH" ;;
  esac
  RESOLVED="$("$GH_REAL" pr view "$SEL" -R "$FIXTURE" --json number -q .number 2>/dev/null)"
  [ "$RESOLVED" = "$PRNUM_A" ] \
    && ok "that selector resolves to the REAL PR laptop A opened (#$RESOLVED)" \
    || bad "the selector resolves to '$RESOLVED', not the real PR #$PRNUM_A"
else
  bad "approve never reached the merge — it did not resolve the PR"
fi
st="$(st_get "$BMDIR/state.json" stage)"
[ "$st" = verify ] && ok "mission still at verify (the fused merge did not fake a Done)" || bad "stage is '$st'"
lbl="$(hostin "$B" issue-labels "$ISSUE" | tr '\n' ' ')"
note "issue labels now: $lbl"
case "$lbl" in *lcars:done*) bad "issue was marked lcars:done without a merge" ;; *) ok "issue NOT marked done" ;; esac

hdr "SPEND"; note "worker spawns: $(spawns)   billable(--model): $(billable)   gh calls: $(gh_calls)"
printf '\nISSUE=%s MID=%s PR=%s\nA=%s\nB=%s\nWORK=%s\n' "$ISSUE" "$MID" "$PRNUM_A" "$A" "$B" "$WORK"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
