#!/usr/bin/env bash
#
# Tests for S75 — Verify auto-opens the PR, then drives the in-review → merge
# lifecycle (skill source: skills/lcars-run/run.sh `open-pr` + the `drive`
# verify path; shared PR builders in skills/lcars-approve/pr-lib.sh).
#
# Behaviours under test (the ones run.sh owns; approve/feedback/host-adapter have
# their own suites):
#   1. Verify all-green opens exactly ONE PR (gh pr create with head/base/title/
#      body); a re-run is IDEMPOTENT (no second PR — prUrl already recorded).
#   2. The Mission lands "in review — PR open": prUrl recorded in state.json,
#      review="open", EXACTLY ONE notification fired, stage still verify (NOT done).
#   3. The driver detects a merge (here or on GitHub via gh pr view) → marks Done;
#      an UNMERGED/open PR never → Done (stays in review, no repeat notification).
#
# Everything is stubbed — NO real gh/git/network. The driver lock makes `drive`
# single-instance; each case uses a fresh repo so locks never collide.
#
# Usage: bash tests/lcars-verify-pr.test.sh

set -uo pipefail
# qgrep reads stdin ONLY when no FILE operand was given. Draining stdin first
# is what keeps a piped `grep -q` from SIGPIPE-ing a still-writing producer and
# flipping a genuine match into a phantom failure under `set -o pipefail`. But
# draining when a FILE was passed reads INHERITED stdin: from a terminal that
# blocks forever, and with stdin closed it silently returns empty and the
# assertion passes by accident. So count the non-option operands ("--" ends the
# options; no call site uses -e/-f, which take an argument) and hand the file
# form straight to grep. Output and exit status match grep in both shapes.
qgrep() {
  local _qg_a _qg_in _qg_n=0 _qg_opt=1
  for _qg_a in "$@"; do
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" = "--" ]; then _qg_opt=0; continue; fi
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" != "${_qg_a#-}" ] && [ "$_qg_a" != "-" ]; then continue; fi
    _qg_n=$((_qg_n + 1))
  done
  if [ "$_qg_n" -ge 2 ]; then grep "$@"; return; fi
  _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"
PR_LIB="$REPO_ROOT/skills/lcars-approve/pr-lib.sh"
HOST_ADAPTER="$REPO_ROOT/skills/lcars-run/host-adapter.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260530-001"
state_of() { echo "$1/.git/lcars/missions/$MID/state.json"; }

# A notify stub that records each ping (one line per call) so we can count them.
make_notify_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "NOTIFY $1 $2 $3" >>"$NOTIFY_LOG"
exit 0
EOF
  chmod +x "$1"
}

# A gh stub. `pr create` echoes a PR URL; `pr view` echoes a merge-state JSON
# driven by $GH_PR_STATE (OPEN|MERGED); everything else records + succeeds.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/repo/pull/77"
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ "${GH_PR_STATE:-OPEN}" = "MERGED" ]; then
    echo '{"state":"MERGED","mergedAt":"2026-06-19T10:00:00Z"}'
  else
    echo '{"state":"OPEN","mergedAt":null}'
  fi
fi
exit 0
EOF
  chmod +x "$1"
}

# Build a repo with one mission parked at verify, all tickets green — the shape
# Implement leaves behind (real branch ahead of base + an origin to push to).
new_repo_verify() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q -b "lcars/$MID" \
      && printf 'x\n' >f.js && git add -A && git commit -q -m "lcars($MID) t-001" \
      && git checkout -q "$base" )
  git init -q --bare "$repo.remote.git"
  ( cd "$repo" && git remote add origin "$repo.remote.git" )
  local m="$repo/.git/lcars/missions/$MID"; mkdir -p "$m"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
**Goal:** Let users switch to a dark colour scheme.
**Acceptance Criteria:**
- A toggle persists the choice
EOF
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "verify",
  "created": "2026-05-30T10:00:00Z",
  "githubIssue": 42,
  "branch": "lcars/$MID",
  "base": "$base"
}
EOF
  cat >"$m/approved-plan.json" <<'EOF'
[ { "id": "t-001", "title": "Add the dark token set" } ]
EOF
  cat >"$m/waves.json" <<'EOF'
[ { "wave": 1, "tickets": [ { "id": "t-001", "issue": 101 } ] } ]
EOF
  echo "$repo"
}

# Drive a run.sh subcommand inside a repo with all the stub bins injected.
run_in() { # repo  subcommand-and-args…
  local repo="$1"; shift
  ( cd "$repo" \
      && LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="git" \
         LCARS_HOST_ADAPTER="$HOST_ADAPTER" LCARS_PR_LIB="$PR_LIB" \
         LCARS_NOTIFY="$repo/notify" NOTIFY_LOG="$repo/notify.log" \
         GH_LOG="$repo/gh.log" GH_PR_STATE="${GH_PR_STATE:-OPEN}" \
         LCARS_NOTIFY_NO_DESKTOP=1 \
         bash "$RUN_SH" "$@" )
}

# S192 (I1) — a host-adapter WRAPPER that records the EXACT argv `pr-create`
# is invoked with (the arg count, every `--closes` value in order, and a marker
# for any EMPTY argv element), then hands off to the REAL adapter so nothing
# else about the run changes. The empty-element marker is the point: the
# bash-3.2-safe form must pass ZERO extra arguments when there is nothing to
# close — `"${CLOSES[@]:-}"` would pass one empty string, which the real
# host-adapter rejects with `pr-create: unknown argument:`.
make_host_recorder() { # <path>
  cat >"$1" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "pr-create" ]; then
  {
    printf 'ARGC:%s\n' "\$#"
    _prev=""
    for _a in "\$@"; do
      [ -n "\$_a" ] || printf 'EMPTY_ARG\n'
      [ "\$_prev" = "--closes" ] && printf 'CLOSES:%s\n' "\$_a"
      _prev="\$_a"
    done
  } >>"\$HOST_LOG"
fi
exec bash "$HOST_ADAPTER" "\$@"
EOF
  chmod +x "$1"
}

# run_in, but routed through the argv recorder above.
run_in_rec() { # repo  subcommand-and-args…
  local repo="$1"; shift
  ( cd "$repo" \
      && LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="git" \
         LCARS_HOST_ADAPTER="$repo/host" LCARS_PR_LIB="$PR_LIB" \
         LCARS_NOTIFY="$repo/notify" NOTIFY_LOG="$repo/notify.log" \
         GH_LOG="$repo/gh.log" HOST_LOG="$repo/host.log" \
         GH_PR_STATE="${GH_PR_STATE:-OPEN}" \
         LCARS_NOTIFY_NO_DESKTOP=1 \
         bash "$RUN_SH" "$@" )
}

# The GREENFIELD shape: filed with NO githubIssue (LCARS Establish Vision files
# day-zero missions with githubIssue: null) and NO sub-issues → CLOSES is EMPTY.
new_repo_verify_no_issue() {
  local repo; repo="$(new_repo_verify)"
  local m="$repo/.git/lcars/missions/$MID"
  sed 's/"githubIssue": 42,/"githubIssue": null,/' "$m/state.json" >"$m/state.tmp" \
    && mv "$m/state.tmp" "$m/state.json"
  # CANONICAL waves.json shape — exactly what emit_waves_json writes (one field
  # per line). Schedule records "issue": null for every ticket when there is no
  # forge issue behind it, which is the day-zero greenfield case.
  cat >"$m/waves.json" <<'WAVES'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  }
]
WAVES
  echo "$repo"
}

# A parent issue PLUS sub-issues (101 listed twice, to pin the dedupe).
new_repo_verify_subs() {
  local repo; repo="$(new_repo_verify)"
  local m="$repo/.git/lcars/missions/$MID"
  cat >"$m/waves.json" <<'WAVES'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 101
      },
      {
        "id": "t-002",
        "issue": 101
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-003",
        "issue": 102
      }
    ]
  }
]
WAVES
  echo "$repo"
}

# ==========================================================================
echo "lcars verify-pr (S75)"

[ -f "$RUN_SH" ] || { echo "run.sh not found at $RUN_SH"; exit 1; }
[ -f "$PR_LIB" ] || { echo "pr-lib.sh not found at $PR_LIB"; exit 1; }

# --- Behaviour 1: open-pr opens exactly one PR; re-run is idempotent ----------
r1="$(new_repo_verify)"; make_gh_stub "$r1/gh"; make_notify_stub "$r1/notify"
: >"$r1/gh.log"; : >"$r1/notify.log"
rc1=0; run_in "$r1" open-pr --mission "$MID" >"$r1/out.txt" 2>&1 || rc1=$?
s1="$(state_of "$r1")"
check "1. open-pr exits 0 on an all-green verify mission" "[ '$rc1' -eq 0 ]"
check "1. calls gh pr create" "grep -q 'pr create' '$r1/gh.log'"
check "1. opens the PR from the mission branch (--head)" \
  "grep -q -- '--head lcars/$MID' '$r1/gh.log'"
check "1. targets the base (--base)" "grep -q -- '--base ' '$r1/gh.log'"
check "1. titles the PR from the PRD" "grep -q 'Add dark mode' '$r1/gh.log'"
check "1. PR body summarises the ticket" "grep -q 't-001' '$r1/gh.log'"
check "1. records prUrl in state.json" "grep -q 'pull/77' '$s1'"
check "1. records the review=open sub-state" "grep -q '\"review\": *\"open\"' '$s1'"
check "1. stays at the verify stage (NOT done)" "grep -q '\"stage\": *\"verify\"' '$s1'"
# Idempotent: a second open-pr opens NO new PR.
: >"$r1/gh.log"
run_in "$r1" open-pr --mission "$MID" >"$r1/out2.txt" 2>&1
check "1. a re-run opens NO second PR (idempotent)" "! grep -q 'pr create' '$r1/gh.log'"

# --- Behaviour 2: drive lands "in review — PR open" with ONE notification -----
r2="$(new_repo_verify)"; make_gh_stub "$r2/gh"; make_notify_stub "$r2/notify"
: >"$r2/gh.log"; : >"$r2/notify.log"
GH_PR_STATE=OPEN
rc2=0; run_in "$r2" drive --mission "$MID" >"$r2/out.txt" 2>&1 || rc2=$?
s2="$(state_of "$r2")"
check "2. drive exits 0 (stops in review)" "[ '$rc2' -eq 0 ]"
check "2. drive opened the PR (prUrl recorded)" "grep -q 'pull/77' '$s2'"
check "2. records review=open" "grep -q '\"review\": *\"open\"' '$s2'"
check "2. stays at verify, NOT done" "grep -q '\"stage\": *\"verify\"' '$s2'"
check "2. fired EXACTLY ONE notification" \
  "[ \"\$(grep -c NOTIFY '$r2/notify.log')\" -eq 1 ]"
check "2. the notification says PR open — review & merge" \
  "grep -qi 'review' '$r2/notify.log' && grep -q 'pull/77' '$r2/notify.log'"
check "2. the banner shows the in-review state" \
  "grep -qi 'in review' '$r2/out.txt'"
# A SECOND drive pass on the open PR must NOT re-notify (one ping at open time).
: >"$r2/notify.log"
run_in "$r2" drive --mission "$MID" >"$r2/out3.txt" 2>&1
check "2. a heartbeat on an open PR does NOT re-notify" \
  "[ \"\$(grep -c NOTIFY '$r2/notify.log')\" -eq 0 ]"
check "2. the heartbeat still reports in review (no false done)" \
  "grep -q '\"stage\": *\"verify\"' '$s2'"

# --- Behaviour 3: a merged PR (on GitHub) → Done; unmerged never → Done -------
r3="$(new_repo_verify)"; make_gh_stub "$r3/gh"; make_notify_stub "$r3/notify"
: >"$r3/gh.log"; : >"$r3/notify.log"
# First pass: open the PR (state OPEN), in review.
GH_PR_STATE=OPEN run_in "$r3" drive --mission "$MID" >"$r3/o1.txt" 2>&1
s3="$(state_of "$r3")"
check "3. opened + in review on first pass" \
  "grep -q 'pull/77' '$s3' && grep -q '\"stage\": *\"verify\"' '$s3'"
# Now the PR is merged on GitHub: the next heartbeat detects it → Done.
GH_PR_STATE=MERGED run_in "$r3" drive --mission "$MID" >"$r3/o2.txt" 2>&1
check "3. a merged-on-GitHub PR is detected → stage done" \
  "grep -q '\"stage\": *\"done\"' '$s3'"
check "3. records review=merged on a detected merge" \
  "grep -q '\"review\": *\"merged\"' '$s3'"
check "3. relabels to lcars:done on a detected merge" \
  "grep -q 'add-label lcars:done' '$r3/gh.log'"

# Contrast: an UNMERGED PR never flips to done (re-uses r2 from above).
check "3. an unmerged/open PR never reaches done" \
  "! grep -q '\"stage\": *\"done\"' '$(state_of "$r2")'"

# --- Behaviour 4 (S111 root-tree sovereignty): open-pr NEVER moves HEAD -------
# The old open_pr checked the mission branch out in the shared checkout before
# pushing — the last site that yanked the captain's working tree onto a mission
# branch (caught live at 002's Verify boundary in the S111 proof drive). Push +
# pr-create are ref-based; the checkout must stay wherever the captain left it.
r4="$(new_repo_verify)"; make_gh_stub "$r4/gh"; make_notify_stub "$r4/notify"
head4_before="$(cd "$r4" && git rev-parse --abbrev-ref HEAD)"
run_in "$r4" open-pr --mission "$MID" >"$r4/out.txt" 2>&1 || :
head4_after="$(cd "$r4" && git rev-parse --abbrev-ref HEAD)"
check "4. open-pr leaves the captain's checkout exactly where it was" \
  "[ '$head4_before' = '$head4_after' ]"
check "4. open-pr still opened the PR without the checkout" \
  "grep -q 'pull/77' '$(state_of "$r4")'"

# --- Behaviour 5 (S192 / ledger I1): a mission with NOTHING to close ---------
# `CLOSES` is an EMPTY array whenever the mission has no githubIssue AND no
# sub-issues — exactly what LCARS Establish Vision produces (greenfield missions
# are filed with githubIssue: null). Under bash 3.2 + `set -u`, a bare
# `"${CLOSES[@]}"` on an empty array raises `CLOSES[@]: unbound variable`, so
# EVERY day-zero mission crashed at the Verify PR-open — and the crash landed
# BEFORE the existing-PR detection, so "open the PR by hand, then re-run" could
# never rescue it. The mission could not leave Verify.
r5="$(new_repo_verify_no_issue)"; make_gh_stub "$r5/gh"; make_notify_stub "$r5/notify"
make_host_recorder "$r5/host"
: >"$r5/gh.log"; : >"$r5/notify.log"; : >"$r5/host.log"
rc5=0; run_in_rec "$r5" open-pr --mission "$MID" >"$r5/out.txt" 2>&1 || rc5=$?
s5="$(state_of "$r5")"
check "5. open-pr does not crash on an empty CLOSES array (bash 3.2 set -u)" \
  "! grep -q 'unbound variable' '$r5/out.txt'"
check "5. open-pr exits 0 with no githubIssue and no sub-issues" "[ '$rc5' -eq 0 ]"
check "5. pr-create is actually invoked" "grep -q '^ARGC:' '$r5/host.log'"
check "5. pr-create gets NO empty/stray argv element" \
  "! grep -q '^EMPTY_ARG$' '$r5/host.log'"
check "5. pr-create gets EXACTLY pr-create+head+base+title+body (9 args, no closes)" \
  "grep -q '^ARGC:9$' '$r5/host.log'"
check "5. no --closes is passed when there is nothing to close" \
  "! grep -q '^CLOSES:' '$r5/host.log'"
check "5. the greenfield mission reaches in-review (prUrl recorded)" \
  "grep -q 'pull/77' '$s5'"

# --- Behaviour 6 (S192 regression): a mission WITH a githubIssue -------------
# Byte-identical to today: the parent issue is still passed as --closes <n>.
r6="$(new_repo_verify)"; make_gh_stub "$r6/gh"; make_notify_stub "$r6/notify"
make_host_recorder "$r6/host"
: >"$r6/gh.log"; : >"$r6/notify.log"; : >"$r6/host.log"
# waves.json in the default fixture carries sub-issue 101; strip it so this case
# isolates the parent-only shape.
cat >"$r6/.git/lcars/missions/$MID/waves.json" <<'WAVES'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  }
]
WAVES
rc6=0; run_in_rec "$r6" open-pr --mission "$MID" >"$r6/out.txt" 2>&1 || rc6=$?
check "6. open-pr exits 0 with a githubIssue" "[ '$rc6' -eq 0 ]"
check "6. the parent issue is still passed as --closes 42" \
  "grep -q '^CLOSES:42$' '$r6/host.log'"
check "6. exactly one --closes (11 args)" "grep -q '^ARGC:11$' '$r6/host.log'"
check "6. still no empty argv element" "! grep -q '^EMPTY_ARG$' '$r6/host.log'"
check "6. gh pr create still carries the Closes directive in the body" \
  "grep -q 'Closes #42' '$r6/gh.log'"

# --- Behaviour 7 (S192 regression): githubIssue AND sub-issues --------------
# Every issue still closed, in order (parent first), deduped exactly as today
# (101 appears twice in waves.json and must be passed once).
r7="$(new_repo_verify_subs)"; make_gh_stub "$r7/gh"; make_notify_stub "$r7/notify"
make_host_recorder "$r7/host"
: >"$r7/gh.log"; : >"$r7/notify.log"; : >"$r7/host.log"
rc7=0; run_in_rec "$r7" open-pr --mission "$MID" >"$r7/out.txt" 2>&1 || rc7=$?
check "7. open-pr exits 0 with a parent + sub-issues" "[ '$rc7' -eq 0 ]"
check "7. closes the parent then each sub-issue, in order, deduped" \
  "[ \"\$(grep '^CLOSES:' '$r7/host.log' | tr '\n' ' ')\" = 'CLOSES:42 CLOSES:101 CLOSES:102 ' ]"
check "7. three --closes pairs (15 args)" "grep -q '^ARGC:15$' '$r7/host.log'"
check "7. still no empty argv element" "! grep -q '^EMPTY_ARG$' '$r7/host.log'"

# --- Behaviour 8: a WRAPPED paragraph survives the PR composer whole ---------
# Observed live: every human-facing paragraph in the PR body stopped at its
# first PHYSICAL source line. The machine-written halves (bullet lists, one-line
# fields) were intact, which is why it went unseen.
#
# The cut points LOOKED like an 80-column budget (most clustered at 78-81), but
# they are not: they are wherever the author's editor hard-wrapped. This fixture
# pins THREE different cut lengths — the Goal wraps at ~70, ADR-001 at ~75, and
# ADR-002 after a 14-character first line. A column-limit "fix" passes the first
# two and fails the third, which is the whole point of having it here.
new_repo_verify_wrapped() {
  local repo; repo="$(new_repo_verify)"
  local m="$repo/.git/lcars/missions/$MID"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
**Goal:** Let users switch to a dark colour scheme so the app is readable
at night, and have that choice remembered the next time they open it.
**Acceptance Criteria:**
- A toggle persists the choice
- The system preference is honoured on first load
EOF
  cat >"$m/adr.md" <<'EOF'
## ADR-001 — Theme storage
**Decision:** Store the theme in localStorage rather than a cookie, because
the server never needs to read it and a cookie would be sent on every
request.
**Consequences:** None worth noting.

## ADR-002 — Toggle placement
**Decision:** In the header.
Next to the account menu, because that is where every other preference
already lives.

## ADR-003 — Token naming
**Decision:** Use CSS custom properties.
EOF
  echo "$repo"
}

r8="$(new_repo_verify_wrapped)"; make_gh_stub "$r8/gh"; make_notify_stub "$r8/notify"
: >"$r8/gh.log"; : >"$r8/notify.log"
rc8=0; run_in "$r8" open-pr --mission "$MID" >"$r8/out.txt" 2>&1 || rc8=$?
check "8. open-pr still exits 0 on a wrapped PRD/ADR" "[ '$rc8' -eq 0 ]"
# The Goal: wrapped at ~70 columns. Everything after the wrap used to vanish.
check "8. the Goal's FIRST source line is still there" \
  "grep -q 'Let users switch to a dark colour scheme' '$r8/gh.log'"
check "8. the Goal's CONTINUATION survives the wrap (~70-col cut point)" \
  "grep -q 'remembered the next time they open it' '$r8/gh.log'"
# ADR-001's decision: wrapped at ~75 columns, over THREE source lines.
check "8. an ADR decision's second source line survives" \
  "grep -q 'the server never needs to read it' '$r8/gh.log'"
check "8. an ADR decision's third source line survives" \
  "grep -q 'sent on every request' '$r8/gh.log'"
# THE DISPROOF OF THE COLUMN THEORY: a 14-character first line, cut just the
# same. A fix built on "it truncates at 80 columns" fails exactly here.
check "8. a SHORT first line (14 chars) also keeps its continuation" \
  "grep -q 'Next to the account menu' '$r8/gh.log'"
check "8. ...all of it, to the last word" \
  "grep -q 'every other preference already lives' '$r8/gh.log'"
# A paragraph is JOINED, never left with a hard wrap inside the sentence.
check "8. the joined paragraph reads as one sentence (no lost space/break)" \
  "grep -q 'app is readable at night' '$r8/gh.log'"
# The value stops where the next label starts — it must NOT swallow it.
check "8. a value does not swallow the NEXT bold label" \
  "! grep -q 'already lives. \\*\\*' '$r8/gh.log'"
check "8. the Goal does not swallow the Acceptance Criteria label" \
  "! grep -q 'open it. Acceptance Criteria' '$r8/gh.log'"
# Regressions: the machine-written halves are byte-identical to today.
check "8. a genuinely one-line ADR decision is unchanged" \
  "grep -q 'Use CSS custom properties.' '$r8/gh.log'"
check "8. every ADR is still listed as its own bullet" \
  "grep -q 'ADR-001' '$r8/gh.log' && grep -q 'ADR-002' '$r8/gh.log' && grep -q 'ADR-003' '$r8/gh.log'"
check "8. the acceptance-criteria bullets are still listed" \
  "grep -q 'A toggle persists the choice' '$r8/gh.log' \
     && grep -q 'The system preference is honoured on first load' '$r8/gh.log'"
check "8. the section headings are unchanged" \
  "grep -q 'User-facing summary' '$r8/gh.log' && grep -q 'Technical summary' '$r8/gh.log'"
check "8. the ADR bullet layout is unchanged (title — decision)" \
  "grep -q -- '- \*\*ADR-001 — Theme storage\*\* — Store the theme' '$r8/gh.log'"

# A HEADING-FORM PRD (no bold labels) wraps its Goal too, and the composer did
# not read it at ALL: its only heading-form path was `lcars_prd_field`, which
# run.sh never sources at open-pr, and that reader takes "the first non-blank
# line under it" anyway. md_scan reads both shapes, whole.
new_repo_verify_headingform() {
  local repo; repo="$(new_repo_verify)"
  local m="$repo/.git/lcars/missions/$MID"
  rm -f "$m/adr.md"
  cat >"$m/prd.md" <<'EOF'
Mission: Add dark mode

## Goal

Let users switch to a dark colour scheme so the app is readable
at night, and have that choice remembered the next time they open it.

## Acceptance Criteria

- A toggle persists the choice
EOF
  echo "$repo"
}
r9="$(new_repo_verify_headingform)"; make_gh_stub "$r9/gh"; make_notify_stub "$r9/notify"
: >"$r9/gh.log"; : >"$r9/notify.log"
rc9=0; run_in "$r9" open-pr --mission "$MID" >"$r9/out.txt" 2>&1 || rc9=$?
check "9. open-pr exits 0 on a heading-form PRD" "[ '$rc9' -eq 0 ]"
check "9. the heading-form Goal's first line is there" \
  "grep -q 'Let users switch to a dark colour scheme' '$r9/gh.log'"
check "9. the heading-form Goal's CONTINUATION survives" \
  "grep -q 'remembered the next time they open it' '$r9/gh.log'"
check "9. the heading-form Goal stops before the next section" \
  "! grep -q 'open it. Acceptance Criteria' '$r9/gh.log'"
check "9. a heading-form PRD's criteria bullets still list" \
  "grep -q 'A toggle persists the choice' '$r9/gh.log'"

# ==========================================================================
echo
printf 'lcars verify-pr: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
