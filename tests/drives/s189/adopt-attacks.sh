#!/usr/bin/env bash
# DRIVE 4 — ATTACKING `lcars adopt` ON REAL GITHUB.
#
#   A. PROSE IMMUNITY — a PRD *about LCARS*: it QUOTES a decoy `lcars:handoff`
#      envelope with a different id/branch/base/type/engine, names a WRONG
#      branch and a WRONG stage in its text, and carries `## Estimate`, `---`
#      rules and the ADR field names. Three sessions have been beaten here. The
#      RECORDED facts (the appended envelope + the `lcars:<stage>` label) must win.
#   B. THE DECOY PR — a second REAL pull request that merely MENTIONS the issue.
#      Adopt must not resolve it as the mission's PR.
#   C. MID-PIPELINE — adopt must refuse, naming the Align/Verify boundary, and
#      leave NOTHING on disk.
#   D. AN ENVELOPE-LESS (pre-round) ISSUE — honest explanation, no half-built dir.
#   E. NO STAGE LABEL — refusal, not a guess.
#   F. IDEMPOTENCY — a second adopt refreshes rather than duplicates, and local
#      artifacts survive.
. "$(dirname "$0")/lib.sh"

A="$(laptop A)"; B="$(laptop B)"
reset_laptop "$A"; reset_laptop "$B"
lcars_config "$A"
CREATED_ISSUES=""; CREATED_PRS=""; CREATED_BRANCHES=""

hdr "A0 — laptop A files a mission whose PRD IS ABOUT LCARS"
cat >"$WORK/prd.md" <<'EOF'
# Mission: Document the LCARS handoff envelope and its adopt path

**Type:** feature
**Goal:** A new crew member can read one page and understand how a Mission travels between laptops, so nobody has to reverse-engineer the envelope from the source again.
**Acceptance Criteria:**
- The page shows a real envelope line verbatim
- The page explains that the STAGE is a label, not an envelope field
- The page states that the mission id is reused by `lcars adopt`, never minted
**Out of Scope:**
- Changing the envelope schema

---

## What the envelope looks like

Every composed body ends with one HTML comment on one line. Here is one, copied
out of a real issue so readers can see the shape:

<!-- lcars:handoff v1 {"id":"lcars-19990101-999","branch":"lcars/DECOY-BRANCH","base":"decoy-base","type":"bug","engine":"copilot","parentIssue":4242,"attachments":7} -->

Note the fields. **Type:** bug is what a bug mission carries there. The branch
above is `lcars/DECOY-BRANCH` and the base is `decoy-base`.

---

## Where the stage lives

The stage is NOT in the envelope. This mission is at `lcars:implement` in the
example below, halfway through the pipeline, on branch `lcars/DECOY-BRANCH`:

    stage: implement
    branch: lcars/DECOY-BRANCH
    id: lcars-19990101-999

## Estimate

Reasoning criticality: **HIGH**. Implementation criticality: **HIGH**.
Estimated cost $999.00–$1999.00.

---

## ADR-001: keep one source per fact

**Context:** Two places recorded the stage and they drifted.
**Decision:** The label owns the stage; the envelope owns identity.
**Alternatives considered:** An envelope `stage` field (rejected: stale by construction).
**Consequences:** Adopt reads a label, not prose.

**Constraints:**
- No new runtime dependencies
EOF
( cd "$A" && LCARS_DATE=20260908 LCARS_NOW=2026-09-08T11:00:00Z bash "$FILE_SH" --prd "$WORK/prd.md" ) >"$WORK/file.out" 2>&1
sed 's/^/    /' "$WORK/file.out" | head -12
MID="$(ls "$A/.git/lcars/missions" | head -1)"; AMDIR="$A/.git/lcars/missions/$MID"
[ -n "$MID" ] || { bad "filing failed"; exit 1; }
ISSUE="$(st_raw "$AMDIR/state.json" githubIssue)"; CREATED_ISSUES="$ISSUE"
BRANCH="$(st_get "$AMDIR/state.json" branch)"
ok "filed $MID as #$ISSUE on branch $BRANCH"
note "the PRD names a DECOY id lcars-19990101-999, branch lcars/DECOY-BRANCH, base decoy-base, type bug, engine copilot, parentIssue 4242, attachments 7, and the stage 'implement'"

hdr "A1 — the issue body really does carry BOTH envelopes"
hostin "$A" issue-body "$ISSUE" >"$WORK/body.md" 2>/dev/null
n_env=$(grep -c '<!-- lcars:handoff ' "$WORK/body.md")
[ "$n_env" = 2 ] && ok "2 envelope lines in the body (1 decoy in the prose, 1 real appended)" || bad "$n_env envelope lines"
note "decoy: $(grep -m1 '<!-- lcars:handoff ' "$WORK/body.md" | cut -c1-120)"
note "real:  $(grep '<!-- lcars:handoff ' "$WORK/body.md" | tail -1 | cut -c1-120)"

hdr "A2 — reach Verify for real (branch, commit, PR)"
fixture_drop_branch "$BRANCH"
( cd "$A" && { git checkout -q "$BRANCH" 2>/dev/null || git checkout -q -b "$BRANCH" main; } \
    && mkdir -p docs && printf '# handoff\n\nthe envelope, explained.\n' > docs/handoff.md \
    && git add -A && git commit -q -m "docs: explain the handoff envelope" ) >/dev/null 2>&1
CREATED_BRANCHES="$BRANCH"
st_set_str "$AMDIR/state.json" stage verify
hostin "$A" issue-relabel "$ISSUE" --add "lcars:verify" --remove "lcars:align" >/dev/null 2>&1
( cd "$A" && bash "$RUN_SH" open-pr --mission "$MID" ) >"$WORK/openpr.out" 2>&1
PRURL="$(st_get "$AMDIR/state.json" prUrl)"; PRNUM="$(st_get "$AMDIR/state.json" prNumber)"
case "$PRURL" in http*) ok "real PR $PRURL"; CREATED_PRS="$PRNUM" ;; *) bad "no PR"; sed 's/^/    /' "$WORK/openpr.out"; exit 1 ;; esac

hdr "B — THE DECOY PR: a real PR that only MENTIONS the issue"
DECOY_BRANCH="s189-decoy-$$"
( cd "$A" && git checkout -q main && git checkout -q -b "$DECOY_BRANCH" \
    && printf 'decoy\n' > DECOY.md && git add -A && git commit -q -m "chore: decoy" \
    && git push -q -u origin "$DECOY_BRANCH" ) >/dev/null 2>&1
CREATED_BRANCHES="$CREATED_BRANCHES $DECOY_BRANCH"
DECOY_PR="$("$GH_REAL" pr create -R "$FIXTURE" --base main --head "$DECOY_BRANCH" \
   --title "s189 decoy — mentions #$ISSUE but closes nothing" \
   --body "This PR is RELATED TO #$ISSUE and references #$ISSUE in passing. It carries no closing directive. Closes nothing." 2>&1 | tail -1)"
note "decoy PR: $DECOY_PR"
case "$DECOY_PR" in http*) ok "decoy PR opened"; CREATED_PRS="$CREATED_PRS ${DECOY_PR##*/}" ;; *) bad "could not open the decoy" ;; esac
( cd "$A" && git checkout -q main ) >/dev/null 2>&1
resolved="$(hostin "$A" issue-closing-prs "$ISSUE" 2>/dev/null)"
note "issue-closing-prs #$ISSUE → $(printf '%s' "$resolved" | tr '\t' ' ' | tr '\n' '|')"
n_res=$(printf '%s\n' "$resolved" | grep -c .)
[ "$n_res" = 1 ] && ok "exactly ONE PR resolves" || bad "$n_res PRs resolved — the decoy leaked in"
printf '%s' "$resolved" | grep -q "$PRURL" && ok "it is the mission's own PR $PRURL" || bad "wrong PR resolved"

hdr "A3 — laptop B adopts it. THE RECORDED FACTS MUST WIN."
( cd "$B" && bash "$ADOPT_SH" "$ISSUE" ) >"$WORK/adopt.out" 2>&1
note "rc=$?"; sed 's/^/    /' "$WORK/adopt.out"
BMDIR="$B/.git/lcars/missions/$MID"
[ -f "$BMDIR/state.json" ] && ok "rebuilt at the REAL id $MID" || bad "no mission at $MID"
[ -d "$B/.git/lcars/missions/lcars-19990101-999" ] && bad "the DECOY id was used for a mission dir" || ok "no mission dir at the decoy id"
chk() { # field expected
  local got; got="$(st_get "$BMDIR/state.json" "$1")"
  [ "$got" = "$2" ] && ok "$1 = '$got' (recorded), not the prose" || bad "$1 = '$got', expected '$2'"
}
chk id "$MID"
chk branch "$BRANCH"
chk base main
chk stage verify
chk type feature
chk prUrl "$PRURL"
gotwb="$(st_get "$BMDIR/state.json" workerBin)"
[ "$gotwb" != copilot ] && ok "workerBin is '$gotwb' — NOT the decoy's 'copilot'" || bad "workerBin took the decoy engine"
gotpi="$(st_raw "$BMDIR/state.json" parentIssue)"
[ -z "$gotpi" ] && ok "no parentIssue (the decoy's 4242 was ignored)" || bad "parentIssue = $gotpi"
grep -q 'DECOY-BRANCH' "$BMDIR/state.json" && bad "the decoy branch reached state.json" || ok "no decoy string anywhere in state.json"
grep -q 'DECOY-BRANCH' "$BMDIR/prd.md" && ok "the decoy text IS still in prd.md (the captain's prose is kept verbatim)" || bad "prd.md lost the captain's text"
note "B state: $(tr -d '\n' <"$BMDIR/state.json")"

hdr "A4 — the rebuilt state.json is VALID JSON"
python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$BMDIR/state.json" 2>"$WORK/json1.err" \
  && ok "valid JSON" || { bad "INVALID JSON: $(tail -1 "$WORK/json1.err")"; sed 's/^/    /' "$BMDIR/state.json"; }

hdr "F — IDEMPOTENCY: adopt again"
printf 'a local note\n' >"$BMDIR/feedback.md"
mkdir -p "$BMDIR/research"; printf '{}\n' >"$BMDIR/research/findings.json"
before_n="$(ls "$B/.git/lcars/missions" | wc -l | tr -d ' ')"
( cd "$B" && bash "$ADOPT_SH" "$ISSUE" ) >"$WORK/adopt2.out" 2>&1
note "rc=$?"; sed 's/^/    /' "$WORK/adopt2.out" | head -12
after_n="$(ls "$B/.git/lcars/missions" | wc -l | tr -d ' ')"
[ "$before_n" = "$after_n" ] && ok "still $after_n mission dir(s) — refreshed, not duplicated" || bad "$before_n → $after_n mission dirs"
[ -f "$BMDIR/feedback.md" ] && ok "feedback.md survived" || bad "feedback.md was destroyed"
[ -f "$BMDIR/research/findings.json" ] && ok "local artifacts survived" || bad "local artifacts destroyed"
grep -q 'refreshed an existing local mission' "$WORK/adopt2.out" && ok "it says it refreshed" || bad "no refresh notice"
python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$BMDIR/state.json" 2>"$WORK/json2.err" \
  && ok "the REFRESHED state.json is valid JSON" \
  || { bad "the REFRESHED state.json is INVALID JSON: $(tail -1 "$WORK/json2.err")"; sed 's/^/    /' "$BMDIR/state.json"; }

hdr "F2 — does the board still see it? (the viewscreen parses state.json with a REAL json parser)"
# `lcars status` reads state.json with sed and does not care about JSON validity.
# The VIEWSCREEN — the captain's primary surface — parses it with json.load, and
# local_adapter._card returns None for a mission it cannot parse. So this is the
# check that says whether a corrupted state.json COSTS anything.
LCARS_SRC="$LCARS_SRC" python3 "$(dirname "$0")/board-probe.py" "$B" "$MID" >"$WORK/board.out" 2>&1
sed 's/^/    /' "$WORK/board.out" | tail -5
grep -q '^PRESENT$' "$WORK/board.out" && ok "the mission is on the viewscreen board after the refresh" \
  || bad "the mission VANISHED from the viewscreen board after the refresh"

hdr "H — ADOPT NEVER STEALS A MISSION"
# The issue really is assigned to roferg; this laptop is told it is someone else.
( cd "$B" && LCARS_GH_USER=not-the-captain bash "$ADOPT_SH" "$ISSUE" ) >"$WORK/steal.out" 2>&1
rc=$?; note "rc=$rc"; sed 's/^/    /' "$WORK/steal.out"
[ "$rc" = 0 ] && ok "a LOOK is not blocked (rc=0)" || bad "adopt refused a look"
grep -qi 'reassign it to yourself on GitHub' "$WORK/steal.out" && ok "it names the owner and the remedy" || bad "no ownership note"
[ "$(hostin "$A" issue-assignees "$ISSUE")" = roferg ] && ok "the assignee on GitHub is UNCHANGED (roferg)" || bad "adopt changed the assignee"

hdr "C — MID-PIPELINE: adopt must refuse and leave nothing"
hostin "$A" issue-relabel "$ISSUE" --add "lcars:implement" --remove "lcars:verify" >/dev/null 2>&1
reset_laptop "$B"
( cd "$B" && bash "$ADOPT_SH" "$ISSUE" ) >"$WORK/mid.out" 2>&1
rc=$?; note "rc=$rc"; sed 's/^/    /' "$WORK/mid.out"
[ "$rc" != 0 ] && ok "refused (rc=$rc)" || bad "adopt SUCCEEDED mid-pipeline"
grep -qi 'mid-pipeline at implement' "$WORK/mid.out" && ok "it names the stage" || bad "it does not name the stage"
grep -qi 'Align and Verify' "$WORK/mid.out" && ok "it names the v1 boundary" || bad "it does not name the boundary"
[ -d "$B/.git/lcars/missions/$MID" ] && bad "a half-built mission dir was left behind" || ok "nothing on disk"
[ -d "$B/.git/lcars" ] && note "(.git/lcars itself: $(ls -a "$B/.git/lcars" 2>/dev/null | tr '\n' ' '))" || ok ".git/lcars was not even created"
hostin "$A" issue-relabel "$ISSUE" --add "lcars:verify" --remove "lcars:implement" >/dev/null 2>&1

hdr "E — NO STAGE LABEL AT ALL: refusal, not a guess"
hostin "$A" issue-relabel "$ISSUE" --add "lcars:mission" --remove "lcars:verify" >/dev/null 2>&1
( cd "$B" && bash "$ADOPT_SH" "$ISSUE" ) >"$WORK/nolabel.out" 2>&1
rc=$?; note "rc=$rc"; sed 's/^/    /' "$WORK/nolabel.out"
[ "$rc" != 0 ] && ok "refused" || bad "adopt guessed a stage"
grep -qi 'no .lcars:<stage>. label\|carries no' "$WORK/nolabel.out" && ok "it says the stage is not recorded" || bad "unclear message"
[ -d "$B/.git/lcars/missions/$MID" ] && bad "half-built dir" || ok "nothing on disk"
hostin "$A" issue-relabel "$ISSUE" --add "lcars:verify" --remove "" >/dev/null 2>&1

hdr "D — AN ENVELOPE-LESS (pre-round) ISSUE"
PLAIN_URL="$("$GH_REAL" issue create -R "$FIXTURE" --title "s189 pre-round mission (no envelope)" \
  --label "lcars:align,lcars:mission" \
  --body "# Mission: an old mission filed before LCARS wrote envelopes

**Type:** feature
**Goal:** exist.
**Acceptance Criteria:**
- exists" 2>&1 | tail -1)"
PLAIN="${PLAIN_URL##*/}"; CREATED_ISSUES="$CREATED_ISSUES $PLAIN"
note "plain issue: #$PLAIN"
before_dirs="$(ls "$B/.git/lcars/missions" 2>/dev/null | wc -l | tr -d ' ')"
( cd "$B" && bash "$ADOPT_SH" "$PLAIN" ) >"$WORK/plain.out" 2>&1
rc=$?; note "rc=$rc"; sed 's/^/    /' "$WORK/plain.out"
[ "$rc" != 0 ] && ok "refused" || bad "adopt built a mission from an envelope-less issue"
grep -qi 'no .lcars:handoff. envelope' "$WORK/plain.out" && ok "it explains what is missing" || bad "it does not name the missing envelope"
grep -qi 'Nothing was created' "$WORK/plain.out" && ok "it says nothing was created" || note "no 'nothing was created' phrasing"
after_dirs="$(ls "$B/.git/lcars/missions" 2>/dev/null | wc -l | tr -d ' ')"
[ "$before_dirs" = "$after_dirs" ] && ok "no half-built mission dir ($after_dirs)" || bad "$before_dirs → $after_dirs"

hdr "G — ADOPT AT ALIGN CLAIMS THE MISSION"
hostin "$A" issue-relabel "$ISSUE" --add "lcars:align" --remove "lcars:verify" >/dev/null 2>&1
hostin "$A" issue-unassign "$ISSUE" roferg >/dev/null 2>&1
note "assignees before: '$(hostin "$A" issue-assignees "$ISSUE")'"
reset_laptop "$B"
( cd "$B" && bash "$ADOPT_SH" "$ISSUE" ) >"$WORK/align.out" 2>&1
note "rc=$?"; sed 's/^/    /' "$WORK/align.out"
[ "$(hostin "$A" issue-assignees "$ISSUE")" = roferg ] && ok "adopt at Align CLAIMED it on GitHub" || bad "adopt did not claim it"
st="$(st_get "$B/.git/lcars/missions/$MID/state.json" stage)"
[ "$st" = align ] && ok "stage align" || bad "stage '$st'"
[ -z "$(st_get "$B/.git/lcars/missions/$MID/state.json" prUrl)" ] && ok "no prUrl at align" || bad "a prUrl was recorded at align"

hdr "TEARDOWN HANDLES (for the tester)"
printf 'ISSUES=%s\nPRS=%s\nBRANCHES=%s\nMID=%s\n' "$CREATED_ISSUES" "$CREATED_PRS" "$CREATED_BRANCHES" "$MID" \
  | tee "$S189_HOME/attack-artifacts" | sed 's/^/    /'

hdr "SPEND"; note "worker spawns: $(spawns)   billable(--model): $(billable)   gh calls: $(gh_calls)"
printf '\n%d passed, %d failed\nWORK=%s\n' "$PASS" "$FAIL" "$WORK"
