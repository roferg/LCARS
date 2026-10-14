#!/usr/bin/env bash
#
# Tests for the REDESIGNED issue-comment mirror (Session 65) — the RICH, LIVING
# (edit-in-place) per-stage comment model that REPLACES the thin one-comment-per-
# event stream the captain rejected.
#
# The new model:
#   * ONE GitHub issue comment per STAGE (Research, Plan, Schedule, Implement,
#     Verify), CREATED once when the stage first needs a comment (that creation
#     is the per-stage notification ping), then EDITED IN PLACE as the stage
#     progresses. A whole mission produces ~5-6 comments total, NOT dozens.
#   * The Implement comment is a LIVE WAVE DASHBOARD that refreshes on every
#     ticket event AND on a ~60s heartbeat while a wave runs.
#   * Rich content: collapsed <details> blocks, #-links to sub-issues, ticket
#     checklists — all rendered from the SHARED renderer (status.sh's
#     compute_progress) so the card / watch / comment never drift.
#   * The dedup/idempotency truth is a stage→comment-id map in comments.json:
#     first render CREATES (POST → record id), every later render EDITS (PATCH
#     that id). A re-run reuses the stored ids and never double-creates.
#   * A human-gate raise posts a NEW (ping) comment, because editing does not
#     notify on GitHub.
#
# Dependencies are env-injected so we stub them and assert the call without
# sending anything:
#   LCARS_GH_BIN              the gh binary (default gh) — stubbed below.
#   LCARS_NOW                 unix stamp (deterministic).
#   LCARS_COMMENT_HEARTBEAT   the Implement heartbeat interval (tiny in tests).
#
# Usage: bash tests/lcars-comment.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }
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

MID="lcars-20260615-001"

# A fake `gh` that records every call to $GH_LOG and, for the comment API calls,
# captures the body (read from stdin via `-f body=@-`, or from a `--body`/--body-file
# argv) into a per-comment-id file under $GH_BODYDIR. It mints a fresh comment id
# for each CREATE and echoes the JSON the adapter parses ({"id":<n>}).
#
# Supported shapes (matching host-adapter's create/edit ops):
#   gh api --method POST   /repos/{owner}/{repo}/issues/<n>/comments  -F body=@-
#   gh api --method PATCH  /repos/{owner}/{repo}/issues/comments/<id> -F body=@-
#
# This stub models REAL `gh api` field semantics so the literal-`@-` defect
# (acme/widget#188) CANNOT pass: only `-F/--field body=@-` reads stdin;
# `-f/--raw-field body=@-` stores the LITERAL string "@-" (gh never reads stdin
# there). So if the adapter regresses to `-f body=@-`, the captured body is the
# 2-char sentinel "@-" and the rich-body assertions fail.
make_gh_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
mode=""; path=""; body=""; have_body=0
while [ $# -gt 0 ]; do
  case "$1" in
    POST) mode="POST" ;;
    PATCH) mode="PATCH" ;;
    repos/*|/repos/*) path="$1" ;;
    -F|--field)
      case "$2" in
        body=@-) body="$(cat)"; have_body=1 ;;      # field @- → STDIN
        body=*)  body="${2#body=}"; have_body=1 ;;
      esac
      shift ;;
    -f|--raw-field)
      case "$2" in
        body=*) body="${2#body=}"; have_body=1 ;;    # raw → ALWAYS literal (incl "@-")
      esac
      shift ;;
    --body-file)
      case "$2" in -) body="$(cat)"; have_body=1 ;; *) body="$(cat "$2")"; have_body=1 ;; esac
      shift ;;
    --body) body="$2"; have_body=1; shift ;;
  esac
  shift
done
# Only the comment API calls carry a body we capture.
case "$path" in
  */issues/*/comments|*/issues/comments/*)
    [ "$have_body" -eq 0 ] && body=""
    if [ "$mode" = "POST" ]; then
      # mint a new id, persist the body under it, echo {"id":<n>}
      n=$(( $(cat "$GH_IDSEQ" 2>/dev/null || echo 100) + 1 ))
      echo "$n" >"$GH_IDSEQ"
      printf '%s' "$body" >"$GH_BODYDIR/$n"
      echo "CREATE $n" >>"$GH_OPS"
      printf '{"id":%s}\n' "$n"
    else
      # PATCH: path tail is the comment id; overwrite its stored body
      cid="${path##*/}"
      printf '%s' "$body" >"$GH_BODYDIR/$cid"
      echo "EDIT $cid" >>"$GH_OPS"
      printf '{"id":%s}\n' "$cid"
    fi
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# A fake `gh` that FAILS every call (graceful-degradation proof).
make_gh_failstub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
exit 7
EOF
  chmod +x "$1"
}

# Build an isolated git repo with a mission. $2 = stage. Returns repo path.
new_repo() { # stage
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "${1:-implement}",
  "githubIssue": 42
}
EOF
  echo "$repo"
}

mdir() { echo "$1/.git/lcars/missions/$MID"; }

# Set the gh-logging env for a repo and zero the logs.
gh_env() { # repo
  export GH_LOG="$1/gh.log";       : >"$GH_LOG"
  export GH_OPS="$1/gh.ops";       : >"$GH_OPS"
  export GH_IDSEQ="$1/gh.idseq";   echo 100 >"$GH_IDSEQ"
  export GH_BODYDIR="$1/gh.bodies"; rm -rf "$GH_BODYDIR"; mkdir -p "$GH_BODYDIR"
}

# Run the mirror once for a repo at $NOW (extra env in $3...).
run_mirror() { # repo now [env...]
  local repo="$1" nowv="$2"; shift 2
  ( cd "$repo" && LCARS_GH_BIN="$repo/gh" LCARS_NOW="$nowv" "$@" \
      bash "$RUN" mirror-comments --mission "$MID" >/dev/null 2>&1 )
}

count_ops() { grep -c "^$1 " "$GH_OPS" 2>/dev/null; true; }

# ==========================================================================
echo "lcars comment-mirror (living per-stage, S65)"

[ -f "$RUN" ] || { echo "run.sh not found at $RUN"; exit 1; }

# --- T1: first render of a stage CREATES one comment + records its id -------
r1="$(new_repo implement)"; make_gh_stub "$r1/gh"; gh_env "$r1"
m1="$(mdir "$r1")"
cat >"$m1/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1003,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (2 ticket(s))","data":{"wave":1,"ticketCount":2,"totalWaves":1}}
{"ts":1004,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
EOF
cat >"$m1/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 143
      },
      {
        "id": "t-002",
        "issue": 144
      }
    ]
  }
]
EOF
rc1=0; run_mirror "$r1" 1010 || rc1=$?
check "T1. mirror exits 0" "[ '$rc1' -eq 0 ]"
check "T1. first render CREATES exactly one comment (POST)" "[ \"\$(count_ops CREATE)\" -eq 1 ]"
check "T1. no EDIT on first render" "[ \"\$(count_ops EDIT)\" -eq 0 ]"
check "T1. a comments.json comment-id map was written" "[ -f '$m1/comments.json' ]"
check "T1. comments.json records the implement stage's comment id" \
  "grep -q '\"implement\"' '$m1/comments.json'"
CID1="$(ls "$GH_BODYDIR" | head -1)"
check "T1. the created comment id was recorded in comments.json" \
  "grep -q '$CID1' '$m1/comments.json'"

# --- T2: a later render of the SAME stage EDITS that comment (PATCH) ---------
: >"$GH_OPS"
cat >>"$m1/events.jsonl" <<'EOF'
{"ts":1020,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_green","detail":"ticket t-001 green in 2 attempt(s)","data":{"ticket":"t-001"}}
EOF
rc2=0; run_mirror "$r1" 1030 || rc2=$?
check "T2. re-render exits 0" "[ '$rc2' -eq 0 ]"
check "T2. re-render of the SAME stage posts NO new comment (no CREATE)" \
  "[ \"\$(count_ops CREATE)\" -eq 0 ]"
check "T2. re-render EDITS the existing comment (PATCH)" \
  "[ \"\$(count_ops EDIT)\" -ge 1 ]"
check "T2. the edit targets the SAME comment id" "[ -f '$GH_BODYDIR/$CID1' ]"

# --- T4: the Implement dashboard body ---------------------------------------
BODY1="$(cat "$GH_BODYDIR/$CID1")"
# Defect guard (acme/widget#188): the CREATEd and EDITed bodies that
# reached gh must be the rendered markdown, NEVER the literal 2-char sentinel
# "@-". With `-f body=@-` the stub captures "@-" and this fails.
check "T4. the CREATEd body is NOT the literal sentinel @-" \
  "[ \"\$BODY1\" != '@-' ] && [ -n \"\$BODY1\" ]"
check "T4. the EDITed body (after the PATCH) is NOT the literal sentinel @-" \
  "[ \"\$(cat \"\$GH_BODYDIR/\$CID1\")\" != '@-' ]"
check "T4. dashboard has the Implement heading" \
  "printf '%s' \"\$BODY1\" | qgrep -qi 'Implement'"
check "T4. dashboard carries the shared progress line (Wave x/y)" \
  "printf '%s' \"\$BODY1\" | qgrep -q 'Wave 1/1'"
check "T4. dashboard shows the per-ticket progress (k/n)" \
  "printf '%s' \"\$BODY1\" | qgrep -qE '\(1/2\)'"
check "T4. dashboard checklist #-links the sub-issues from waves.json" \
  "printf '%s' \"\$BODY1\" | qgrep -q '#143' && printf '%s' \"\$BODY1\" | qgrep -q '#144'"
check "T4. dashboard marks the green ticket DONE (checked)" \
  "printf '%s' \"\$BODY1\" | qgrep -q '\\- \\[x\\].*t-001'"
check "T4. dashboard footer says it auto-refreshes" \
  "printf '%s' \"\$BODY1\" | qgrep -qi 'auto-refresh'"

# Re-render after t-002 also greens → it flips to done too.
: >"$GH_OPS"
cat >>"$m1/events.jsonl" <<'EOF'
{"ts":1040,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-002 starting","data":{"ticket":"t-002","wave":1}}
{"ts":1050,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_green","detail":"ticket t-002 green in 1 attempt(s)","data":{"ticket":"t-002"}}
EOF
run_mirror "$r1" 1060
BODY2="$(cat "$GH_BODYDIR/$CID1")"
check "T4. a new ticket_green flips that ticket to done on re-render" \
  "printf '%s' \"\$BODY2\" | qgrep -q '\\- \\[x\\].*t-002'"

# --- T3: a whole synthetic mission yields ~one comment per stage ------------
r3="$(new_repo implement)"; make_gh_stub "$r3/gh"; gh_env "$r3"
m3="$(mdir "$r3")"
mkdir -p "$m3/research"
cat >"$m3/research/1.json" <<'EOF'
{"question":"Which theme tokens?","recommendation":"Reuse CSS vars","supporting_points":["x"]}
EOF
cat >"$m3/plan.json" <<'EOF'
[
  { "id": "t-001", "title": "Token layer", "description": "d", "rationale": "r", "acceptanceCriteria": ["c1"], "dependencies": [] },
  { "id": "t-002", "title": "Toggle UI", "description": "d", "rationale": "r", "acceptanceCriteria": ["c2"], "dependencies": ["t-001"] }
]
EOF
cat >"$m3/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 143
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-002",
        "issue": 144
      }
    ]
  }
]
EOF
cat >"$m3/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"research","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"research","type":"stage_done","detail":"1 question(s) → findings saved"}
{"ts":1002,"mission":"lcars-20260615-001","stage":"plan","type":"stage_start","detail":"starting"}
{"ts":1003,"mission":"lcars-20260615-001","stage":"plan","type":"stage_done","detail":"2 ticket(s)"}
{"ts":1004,"mission":"lcars-20260615-001","stage":"schedule","type":"stage_start","detail":"starting"}
{"ts":1005,"mission":"lcars-20260615-001","stage":"schedule","type":"stage_done","detail":"2 wave(s)"}
{"ts":1006,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1007,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (1 ticket(s))","data":{"wave":1,"ticketCount":1,"totalWaves":2}}
{"ts":1008,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
{"ts":1009,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_green","detail":"ticket t-001 green in 1 attempt(s)","data":{"ticket":"t-001"}}
EOF
run_mirror "$r3" 2000
NTOTAL="$(count_ops CREATE)"
# research + plan + schedule + implement = 4 distinct comments, NOT one per event.
check "T3. a whole mission yields ~one comment per stage (4 creates, not per-event)" \
  "[ \"\$NTOTAL\" -ge 3 ] && [ \"\$NTOTAL\" -le 5 ]"
check "T3. comments.json holds the research stage id" "grep -q '\"research\"' '$m3/comments.json'"
check "T3. comments.json holds the plan stage id"     "grep -q '\"plan\"' '$m3/comments.json'"
check "T3. comments.json holds the schedule stage id" "grep -q '\"schedule\"' '$m3/comments.json'"
check "T3. comments.json holds the implement stage id" "grep -q '\"implement\"' '$m3/comments.json'"
# Re-run over the same log → NO new creates (idempotent across the whole mission).
: >"$GH_OPS"
run_mirror "$r3" 2100
check "T3. re-running the whole mission creates NO new comments" \
  "[ \"\$(count_ops CREATE)\" -eq 0 ]"

# --- T5: Research comment Q&A in a <details> block --------------------------
# Find the research comment id from comments.json and read its captured body.
# The stub body dir for a given mission dir (repo/.git/lcars/... → repo/gh.bodies).
bodydir_for() { local md="$1"; printf '%s/gh.bodies' "${md%%/.git/*}"; }
stage_body() { # mdir stage
  local bd cid; bd="$(bodydir_for "$1")"
  cid="$(sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$1/comments.json" | head -1)"
  [ -n "$cid" ] && cat "$bd/$cid"
}
research_body() { stage_body "$1" research; }
RBODY="$(research_body "$m3")"
check "T5. research comment has a <details> Q&A block" \
  "printf '%s' \"\$RBODY\" | qgrep -qi '<details>'"
check "T5. research comment surfaces the question text" \
  "printf '%s' \"\$RBODY\" | qgrep -qi 'theme tokens'"
check "T5. research comment surfaces the finding/recommendation" \
  "printf '%s' \"\$RBODY\" | qgrep -qi 'Reuse CSS vars'"

# Degradation: a 0-question research (no research/*.json, no pending.json) →
# the "unambiguous — 0 questions" message, no fabricated Q&A.
r5="$(new_repo plan)"; make_gh_stub "$r5/gh"; gh_env "$r5"
m5="$(mdir "$r5")"
cat >"$m5/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"research","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"research","type":"stage_done","detail":"0 questions (PRD unambiguous)"}
EOF
run_mirror "$r5" 1100
RBODY5="$(research_body "$m5")"
check "T5. 0-question research degrades to the unambiguous message" \
  "printf '%s' \"\$RBODY5\" | qgrep -qi 'unambiguous\\|0 question'"

# --- T6: Schedule comment #-links the per-ticket sub-issues -----------------
sched_body() { stage_body "$1" schedule; }
SBODY="$(sched_body "$m3")"
check "T6. schedule comment names Wave 1" "printf '%s' \"\$SBODY\" | qgrep -qi 'Wave 1'"
check "T6. schedule comment #-links sub-issue #143" "printf '%s' \"\$SBODY\" | qgrep -q '#143'"
check "T6. schedule comment #-links sub-issue #144" "printf '%s' \"\$SBODY\" | qgrep -q '#144'"
check "T6. schedule comment lists the ticket ids" \
  "printf '%s' \"\$SBODY\" | qgrep -q 't-001' && printf '%s' \"\$SBODY\" | qgrep -q 't-002'"

# --- T7: heartbeat re-PATCHes the Implement comment + no orphan -------------
# Drive the Implement stage's heartbeat directly: with a tiny interval and a
# bounded lifetime, the Implement comment must be PATCHed at least once MORE than
# the initial render (elapsed advances with no new event), and the ticker process
# must be gone afterward (no orphan).
r7="$(new_repo implement)"; make_gh_stub "$r7/gh"; gh_env "$r7"
m7="$(mdir "$r7")"
cat >"$m7/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 143
      }
    ]
  }
]
EOF
cat >"$m7/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (1 ticket(s))","data":{"wave":1,"ticketCount":1,"totalWaves":1}}
{"ts":1002,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
EOF
# Create the initial comment.
run_mirror "$r7" 1010
: >"$GH_OPS"
# Run the heartbeat for a bounded number of ticks with a tiny interval. The
# subcommand starts the ticker, lets it tick, then stops it cleanly.
HB_LOG="$r7/hb.pids"
rc7=0
( cd "$r7" && LCARS_GH_BIN="$r7/gh" LCARS_COMMENT_HEARTBEAT=1 LCARS_COMMENT_HEARTBEAT_TICKS=2 \
    bash "$RUN" comment-heartbeat-test --mission "$MID" >"$HB_LOG" 2>&1 ) || rc7=$?
check "T7. heartbeat-test exits 0" "[ '$rc7' -eq 0 ]"
check "T7. heartbeat PATCHes the Implement comment with no new event" \
  "[ \"\$(count_ops EDIT)\" -ge 1 ]"
# The ticker pid the heartbeat reported must no longer be alive (no orphan).
HB_PID="$(sed -n 's/^TICK_PID=//p' "$HB_LOG" | head -1)"
check "T7. heartbeat reported a ticker pid" "[ -n '$HB_PID' ]"
check "T7. the heartbeat ticker is killed cleanly (no orphan)" \
  "! kill -0 '$HB_PID' 2>/dev/null"

# --- T8: gh absent/failing → exit 0; human gate posts a NEW ping comment ----
r8="$(new_repo implement)"; make_gh_failstub "$r8/gh"; gh_env "$r8"
m8="$(mdir "$r8")"
cat >"$m8/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
EOF
rc8=0; run_mirror "$r8" 1010 || rc8=$?
check "T8a. gh FAILING → mirror still exits 0" "[ '$rc8' -eq 0 ]"

r8b="$(new_repo implement)"; gh_env "$r8b"
m8b="$(mdir "$r8b")"
cat >"$m8b/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
EOF
rc8b=0
( cd "$r8b" && LCARS_GH_BIN="$r8b/definitely-not-real" LCARS_NOW=1010 \
    bash "$RUN" mirror-comments --mission "$MID" >/dev/null 2>&1 ) || rc8b=$?
check "T8b. gh ABSENT → mirror still exits 0" "[ '$rc8b' -eq 0 ]"

# Human gate: a NEW (ping) comment is posted in ADDITION to whatever else.
r8c="$(new_repo implement)"; make_gh_stub "$r8c/gh"; gh_env "$r8c"
m8c="$(mdir "$r8c")"
cat >"$m8c/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"implement","type":"gate","detail":"ticket t-002 needs your answer after 5 attempt(s)"}
EOF
rc8c=0; run_mirror "$r8c" 1010 || rc8c=$?
check "T8c. a human gate posts a NEW ping comment (a CREATE for the gate)" \
  "[ \"\$(count_ops CREATE)\" -ge 1 ]"
# The gate ping body carries the pending question text.
GATE_HIT=0
for f in "$GH_BODYDIR"/*; do grep -qi 'needs your answer' "$f" 2>/dev/null && GATE_HIT=1; done
check "T8c. the gate ping body carries the pending question" "[ '$GATE_HIT' -eq 1 ]"

# Re-running over the same gate event does NOT re-ping (idempotent gate).
: >"$GH_OPS"
run_mirror "$r8c" 1020
GATE_RECREATES="$(count_ops CREATE)"
check "T8c. re-running does NOT re-ping the same gate (idempotent)" \
  "[ '$GATE_RECREATES' -eq 0 ]"

# --- Guard: no githubIssue → clean no-op ------------------------------------
r9="$(new_repo implement)"; make_gh_stub "$r9/gh"; gh_env "$r9"
m9="$(mdir "$r9")"
sed 's/"githubIssue": 42/"githubIssue": null/' "$m9/state.json" >"$m9/state.tmp" && mv "$m9/state.tmp" "$m9/state.json"
cat >"$m9/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
EOF
rc9=0; run_mirror "$r9" 1010 || rc9=$?
check "guard. no githubIssue → exit 0, posts nothing" \
  "[ '$rc9' -eq 0 ] && [ \"\$(count_ops CREATE)\" -eq 0 ]"

# --- Guard: no events.jsonl yet → clean no-op -------------------------------
r10="$(new_repo implement)"; make_gh_stub "$r10/gh"; gh_env "$r10"
rc10=0; run_mirror "$r10" 1010 || rc10=$?
check "guard. no events.jsonl yet → exit 0, no comments" \
  "[ '$rc10' -eq 0 ] && [ \"\$(count_ops CREATE)\" -eq 0 ]"

# --- T9 (BUG A): Research Q&A blocks are separated by a BLANK LINE so a `>`
# blockquote can't lazily continue onto the next question, and a MULTI-LINE
# answer has EVERY line `>`-prefixed. -----------------------------------------
r11="$(new_repo plan)"; make_gh_stub "$r11/gh"; gh_env "$r11"
m11="$(mdir "$r11")"
mkdir -p "$m11/research"
# Two questions; the SECOND has a multi-line recommendation (json_str leaves the
# \n escapes literal, the renderer normalises + prefixes each line with "> ").
cat >"$m11/research/1.json" <<'EOF'
{"question":"Which theme tokens?","recommendation":"Reuse the existing CSS vars."}
EOF
cat >"$m11/research/2.json" <<'EOF'
{"question":"How to persist?","recommendation":"Store in localStorage.\nFall back to a cookie.\nDefault to system preference."}
EOF
cat >"$m11/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"research","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"research","type":"stage_done","detail":"2 question(s)"}
EOF
run_mirror "$r11" 1100
RBODY11="$(research_body "$m11")"
# Both questions render.
check "T9. Q&A renders Q1" "printf '%s' \"\$RBODY11\" | qgrep -q '\\*\\*Q1\\.\\*\\*'"
check "T9. Q&A renders Q2" "printf '%s' \"\$RBODY11\" | qgrep -q '\\*\\*Q2\\.\\*\\*'"
# A BLANK LINE separates Q1's answer block from **Q2.** — assert that the line
# IMMEDIATELY preceding the **Q2.** line is empty (the blockquote terminator).
q2line="$(printf '%s\n' "$RBODY11" | grep -n '\*\*Q2\.\*\*' | head -1 | cut -d: -f1)"
prevline="$(printf '%s\n' "$RBODY11" | sed -n "$((q2line-1))p")"
check "T9. a BLANK LINE precedes **Q2.** (blockquote terminates)" \
  "[ -z \"\$prevline\" ]"
# The first answer is a blockquote.
check "T9. Q1's answer is a blockquote" \
  "printf '%s' \"\$RBODY11\" | qgrep -q '^> Reuse the existing CSS vars\\.'"
# EVERY line of the multi-line answer is `>`-prefixed (all three lines).
check "T9. multi-line answer line 1 is >-prefixed" \
  "printf '%s' \"\$RBODY11\" | qgrep -q '^> Store in localStorage\\.'"
check "T9. multi-line answer line 2 is >-prefixed (continuation)" \
  "printf '%s' \"\$RBODY11\" | qgrep -q '^> Fall back to a cookie\\.'"
check "T9. multi-line answer line 3 is >-prefixed (continuation)" \
  "printf '%s' \"\$RBODY11\" | qgrep -q '^> Default to system preference\\.'"
# No line of the multi-line answer leaks OUT of the blockquote (no bare line).
check "T9. no continuation line escapes the blockquote (no bare 'Fall back')" \
  "! printf '%s' \"\$RBODY11\" | qgrep -qE '^Fall back to a cookie'"
# A single-question case still reads right (one Q, one >-answer).
r12="$(new_repo plan)"; make_gh_stub "$r12/gh"; gh_env "$r12"
m12="$(mdir "$r12")"
mkdir -p "$m12/research"
cat >"$m12/research/1.json" <<'EOF'
{"question":"Only one?","recommendation":"Yes, single answer."}
EOF
cat >"$m12/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"research","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"research","type":"stage_done","detail":"1 question(s)"}
EOF
run_mirror "$r12" 1100
RBODY12="$(research_body "$m12")"
check "T9. single-question case renders the question" \
  "printf '%s' \"\$RBODY12\" | qgrep -q 'Only one?'"
check "T9. single-question case renders a >-prefixed answer" \
  "printf '%s' \"\$RBODY12\" | qgrep -q '^> Yes, single answer\\.'"

# --- T10 (BUG B): sequential checklist states — exactly ONE in-progress -------
# t-001 green, t-002 started (current, attempt 2), t-003 never started.
r13="$(new_repo implement)"; make_gh_stub "$r13/gh"; gh_env "$r13"
m13="$(mdir "$r13")"
cat >"$m13/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 201
      },
      {
        "id": "t-002",
        "issue": 202
      },
      {
        "id": "t-003",
        "issue": 203
      }
    ]
  }
]
EOF
cat >"$m13/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (3 ticket(s))","data":{"wave":1,"ticketCount":3,"totalWaves":1}}
{"ts":1002,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
{"ts":1003,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_green","detail":"ticket t-001 green in 1 attempt(s)","data":{"ticket":"t-001","attempts":1}}
{"ts":1004,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-002 starting","data":{"ticket":"t-002","wave":1}}
{"ts":1005,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"implementer try 1 for t-002","data":{"ticket":"t-002","phase":"implementer","attempt":1}}
{"ts":1006,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"implementer try 2 for t-002","data":{"ticket":"t-002","phase":"implementer","attempt":2}}
EOF
run_mirror "$r13" 1100
IBODY13="$(stage_body "$m13" implement)"
check "T10. t-001 is DONE (checked)" \
  "printf '%s' \"\$IBODY13\" | qgrep -q '\\- \\[x\\].*t-001'"
check "T10. t-002 is in progress on its 2nd hire (S173 hire vocabulary)" \
  "printf '%s' \"\$IBODY13\" | qgrep -qE '\\- \\[ \\].*t-002.*in progress, hire 2 of 3'"
check "T10b. the retired word 'attempt' is gone from the ticket checklist" \
  "! printf '%s' \"\$IBODY13\" | qgrep -qiE '\\- \\[.\\].*attempt'"
check "T10. t-003 is pending (unchecked, no in-progress)" \
  "printf '%s' \"\$IBODY13\" | qgrep -qE '\\- \\[ \\].*t-003' && ! printf '%s' \"\$IBODY13\" | qgrep -qE 't-003.*in progress'"
NIP13="$(printf '%s\n' "$IBODY13" | grep -c 'in progress')"
check "T10. EXACTLY ONE line says 'in progress'" "[ \"\$NIP13\" -eq 1 ]"

# --- T11 (BUG B): flagged is DISTINCT from in-progress ------------------------
# t-001 started, attempts up to 5, then flagged; no green.
r14="$(new_repo implement)"; make_gh_stub "$r14/gh"; gh_env "$r14"
m14="$(mdir "$r14")"
cat >"$m14/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 301
      },
      {
        "id": "t-002",
        "issue": 302
      }
    ]
  }
]
EOF
cat >"$m14/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (2 ticket(s))","data":{"wave":1,"ticketCount":2,"totalWaves":1}}
{"ts":1002,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
{"ts":1003,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"implementer try 1 for t-001","data":{"ticket":"t-001","phase":"implementer","attempt":1}}
{"ts":1004,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"implementer try 2 for t-001","data":{"ticket":"t-001","phase":"implementer","attempt":2}}
{"ts":1005,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"implementer try 3 for t-001","data":{"ticket":"t-001","phase":"implementer","attempt":3}}
{"ts":1006,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"implementer try 4 for t-001","data":{"ticket":"t-001","phase":"implementer","attempt":4}}
{"ts":1007,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"implementer try 5 for t-001","data":{"ticket":"t-001","phase":"implementer","attempt":5}}
{"ts":1008,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_flagged","detail":"ticket t-001 flagged after 5 attempt(s)","data":{"ticket":"t-001","attempts":5}}
EOF
run_mirror "$r14" 1100
IBODY14="$(stage_body "$m14" implement)"
check "T11. flagged ticket renders '(flagged after 5 worker sessions)'" \
  "printf '%s' \"\$IBODY14\" | qgrep -qE '\\- \\[ \\].*t-001.*flagged after 5 worker sessions'"
check "T11b. the flagged suffix does NOT say 'attempt'" \
  "! printf '%s' \"\$IBODY14\" | qgrep -qiE '\\- \\[.\\].*t-001.*attempt'"
check "T11. flagged ticket is NOT marked 'in progress'" \
  "! printf '%s' \"\$IBODY14\" | qgrep -qE 't-001.*in progress'"
NIP14="$(printf '%s\n' "$IBODY14" | grep -c 'in progress')"
check "T11. a flagged-only wave shows ZERO in-progress lines" "[ \"\$NIP14\" -eq 0 ]"

# --- T12 (BUG B): the checklist in-progress ticket AGREES with the progress
# line's `ticket <id>` (single source of truth). ------------------------------
# Reuse r13 (t-002 is current). The shared progress line must name ticket t-002
# AND the checklist's sole in-progress line must be t-002.
PROGLINE13="$(printf '%s\n' "$IBODY13" | grep '^Wave ' | head -1)"
check "T12. progress line names ticket t-002" \
  "printf '%s' \"\$PROGLINE13\" | qgrep -q 'ticket t-002'"
IPLINE13="$(printf '%s\n' "$IBODY13" | grep 'in progress' | head -1)"
check "T12. the checklist in-progress line is t-002 (agrees with progress line)" \
  "printf '%s' \"\$IPLINE13\" | qgrep -q 't-002'"

# --- T13 (BUG B): a started-but-SUPERSEDED non-current ticket is pending, not
# in-progress (edge case: two starts, neither green, last wins). --------------
r15="$(new_repo implement)"; make_gh_stub "$r15/gh"; gh_env "$r15"
m15="$(mdir "$r15")"
cat >"$m15/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 401
      },
      {
        "id": "t-002",
        "issue": 402
      }
    ]
  }
]
EOF
cat >"$m15/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (2 ticket(s))","data":{"wave":1,"ticketCount":2,"totalWaves":1}}
{"ts":1002,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
{"ts":1003,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-002 starting","data":{"ticket":"t-002","wave":1}}
EOF
run_mirror "$r15" 1100
IBODY15="$(stage_body "$m15" implement)"
NIP15="$(printf '%s\n' "$IBODY15" | grep -c 'in progress')"
check "T13. only ONE in-progress despite two ticket_starts (last wins)" \
  "[ \"\$NIP15\" -eq 1 ]"
check "T13. the superseded earlier start (t-001) is NOT in progress" \
  "! printf '%s' \"\$IBODY15\" | qgrep -qE 't-001.*in progress'"
check "T13. the current (t-002) IS the in-progress ticket" \
  "printf '%s' \"\$IBODY15\" | qgrep -qE 't-002.*in progress'"

# --- T14 (S173 FIX ROUND, D3): a DONE ticket line is no longer byte-identical
# whether it took 1 hire or 3 hires + 2 bounces. Hires AND bounces are readable
# off the mirror WITHOUT opening a ticket — and a clean ticket wears no counter,
# the same silence rule as the board chip. ----------------------------------
r16="$(new_repo implement)"; make_gh_stub "$r16/gh"; gh_env "$r16"
m16="$(mdir "$r16")"
cat >"$m16/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 501
      },
      {
        "id": "t-002",
        "issue": 502
      },
      {
        "id": "t-003",
        "issue": 503
      }
    ]
  }
]
EOF
cat >"$m16/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (3 ticket(s))","data":{"wave":1,"ticketCount":3,"totalWaves":1}}
{"ts":1002,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
{"ts":1003,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"tdd session 1 for t-001","data":{"ticket":"t-001","phase":"tdd","attempt":1}}
{"ts":1004,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_green","detail":"ticket t-001 green","data":{"ticket":"t-001","sessions":1,"iterations":6}}
{"ts":1005,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-002 starting","data":{"ticket":"t-002","wave":1}}
{"ts":1006,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"tdd session 1 for t-002","data":{"ticket":"t-002","phase":"tdd","attempt":1}}
{"ts":1007,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_gate_bounce","detail":"ticket t-002 bounced by the flip-flop gate (FAIL) — session 1; re-spawning a fresh worker with the verdict","data":{"ticket":"t-002","gate":"flip-flop","attempt":1}}
{"ts":1008,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"tdd session 2 for t-002","data":{"ticket":"t-002","phase":"tdd","attempt":2}}
{"ts":1009,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_gate_bounce","detail":"ticket t-002 bounced by the declared-edits gate (FAIL) — session 2; re-spawning a fresh worker with the verdict","data":{"ticket":"t-002","gate":"declared-edits","attempt":2}}
{"ts":1010,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"tdd session 3 for t-002","data":{"ticket":"t-002","phase":"tdd","attempt":3}}
{"ts":1011,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_green","detail":"ticket t-002 green after 3 worker sessions","data":{"ticket":"t-002","sessions":3,"iterations":2}}
{"ts":1012,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-003 starting","data":{"ticket":"t-003","wave":1}}
EOF
run_mirror "$r16" 1100
IBODY16="$(stage_body "$m16" implement)"
DONE1_16="$(printf '%s\n' "$IBODY16" | grep 't-001' | head -1)"
DONE2_16="$(printf '%s\n' "$IBODY16" | grep 't-002' | head -1)"
check "T14. a CLEAN done ticket wears no counter at all" \
  "printf '%s' \"\$DONE1_16\" | qgrep -qE '^\\- \\[x\\] #501 . t-001$'"
check "T14. a 3-hire / 2-bounce done ticket names BOTH, in the round's vocabulary" \
  "printf '%s' \"\$DONE2_16\" | qgrep -qF '3 worker sessions, 2 bounces'"
# compares only the SUFFIX past the ticket id, so the ids themselves cannot
# make two structurally identical lines look different.
check "T14. the done-line SUFFIXES are no longer byte-identical" \
  "[ \"\${DONE1_16#*t-001}\" != \"\${DONE2_16#*t-002}\" ]"
check "T14. the word 'bounce' now appears in the mirror" \
  "printf '%s' \"\$IBODY16\" | qgrep -q 'bounce'"
check "T14. neither done line says 'attempt'" \
  "! printf '%s' \"\$DONE1_16\$DONE2_16\" | qgrep -qi 'attempt'"
check "T14. the worker's own iteration count (6) never reaches the mirror" \
  "! printf '%s' \"\$DONE1_16\" | qgrep -q '6'"

# --- T15 (S173 FIX ROUND, D2): ONE derivation rule — the hire count is the
# NUMBER of ticket_attempt events, ANY phase; never the max `attempt` VALUE. --
r17="$(new_repo implement)"; make_gh_stub "$r17/gh"; gh_env "$r17"
m17="$(mdir "$r17")"
cat >"$m17/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 601
      },
      {
        "id": "t-002",
        "issue": 602
      }
    ]
  }
]
EOF
# t-001: the PRE-S133 standoff shape — two dispatches, both numbered attempt=1
# (the old loops numbered PER PHASE). Max VALUE = 1; EVENT COUNT = 2.
# t-002: a GAP in the indices (1 then 3). Max VALUE = 3; EVENT COUNT = 2.
cat >"$m17/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (2 ticket(s))","data":{"wave":1,"ticketCount":2,"totalWaves":1}}
{"ts":1002,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
{"ts":1003,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"test-writer try 1 for t-001","data":{"ticket":"t-001","phase":"test-writer","attempt":1}}
{"ts":1004,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"implementer try 1 for t-001","data":{"ticket":"t-001","phase":"implementer","attempt":1}}
{"ts":1005,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_flagged","detail":"ticket t-001 flagged","data":{"ticket":"t-001","sessions":2}}
{"ts":1006,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-002 starting","data":{"ticket":"t-002","wave":1}}
{"ts":1007,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"tdd session 1 for t-002","data":{"ticket":"t-002","phase":"tdd","attempt":1}}
{"ts":1008,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"tdd session 3 for t-002","data":{"ticket":"t-002","phase":"tdd","attempt":3}}
EOF
run_mirror "$r17" 1100
IBODY17="$(stage_body "$m17" implement)"
check "T15. a pre-S133 two-phase ticket counts TWO hires (events, not the max index 1)" \
  "printf '%s' \"\$IBODY17\" | qgrep -qE '\\- \\[ \\].*t-001.*flagged after 2 worker sessions'"
check "T15. a GAPPED index stream counts TWO hires (events, not the max index 3)" \
  "printf '%s' \"\$IBODY17\" | qgrep -qE '\\- \\[ \\].*t-002.*in progress, hire 2 of 3'"

# --- T16 (S173 FIX ROUND 2, N1): CROSS-SURFACE AGREEMENT on the measured shape.
# One ticket, THREE hires and TWO bounces, with a `stage_start` RE-ENTRY after
# hire 2. HONEST LABEL: a REGRESSION GUARD for the mirror — cm_ticket_sessions()
# already read the WHOLE events file, so it says 3 on both sides of fix round 2.
# The cure is in board.js (whose per-SECTION derivation said 2); this pins the
# number the board must now agree with, on the same stream.
r18="$(new_repo implement)"; make_gh_stub "$r18/gh"; gh_env "$r18"
m18="$(mdir "$r18")"
cat >"$m18/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 611
      }
    ]
  }
]
EOF
cat >"$m18/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"implement starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (1 ticket(s))","data":{"wave":1,"ticketCount":1,"totalWaves":1}}
{"ts":1002,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
{"ts":1003,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"tdd session 1 for t-001","data":{"ticket":"t-001","phase":"tdd","attempt":1}}
{"ts":1004,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_gate_bounce","detail":"ticket t-001 bounced by the flip-flop gate (FAIL)","data":{"ticket":"t-001","gate":"flip-flop","attempt":1}}
{"ts":1005,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"tdd session 2 for t-001","data":{"ticket":"t-001","phase":"tdd","attempt":2}}
{"ts":1006,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_gate_bounce","detail":"ticket t-001 bounced by the declared-edits gate (FAIL)","data":{"ticket":"t-001","gate":"declared-edits","attempt":2}}
{"ts":1007,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"implement resuming"}
{"ts":1008,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"tdd session 3 for t-001","data":{"ticket":"t-001","phase":"tdd","attempt":3}}
{"ts":1009,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_flagged","detail":"ticket t-001 flagged","data":{"ticket":"t-001","sessions":3}}
EOF
run_mirror "$r18" 1101
IBODY18="$(stage_body "$m18" implement)"
check "T16. REGRESSION GUARD: the mirror counts 3 hires ACROSS a stage_start re-entry" \
  "printf '%s' \"\$IBODY18\" | qgrep -qE 't-001.*flagged after 3 worker sessions'"
check "T16. …and 2 bounces, both counted wherever they sit in the stream" \
  "printf '%s' \"\$IBODY18\" | qgrep -q '2 bounces'"


# --- T17 (S202): NUMBER ONE'S REPORT — one living comment, edited in place ---
#
# The first officer's record on the issue is ONE more key in the S65 model, not
# a new mechanism: `number-one` in comments.json, CREATED the first time it has
# anything to say and PATCHed for ever after. A comment per action is the defect
# this block exists to catch — two answers must still be ONE comment.
#
# The ONE exception is an ESCALATION, and it is the same exception S65 already
# makes: an edit does not notify on GitHub, so a gate that is now the captain's
# gets a FRESH comment through cm_ping_gate. That is a ping, not a second report.
r17="$(new_repo implement)"; make_gh_stub "$r17/gh"; gh_env "$r17"
m17="$(mdir "$r17")"
# Engage Number One on the mission, the way the driver does.
awk 'NR==1{print; print "  \"numberOne\": {\"status\": \"engaged\", \"engine\": \"copilot\", \"since\": \"2026-09-12T10:00:00Z\", \"lastAction\": \"answered schedule 10:04\"},"; next} {print}' \
  "$m17/state.json" >"$m17/state.tmp" && mv "$m17/state.tmp" "$m17/state.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m17/state.json" \
  || { echo "T17 FIXTURE IS NOT VALID JSON"; exit 1; }
cat >"$m17/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
EOF
cat >"$m17/number-one.jsonl" <<'EOF'
{"at": "2026-09-12T10:04:00Z", "action": "answered", "stage": "schedule", "answer": "No — the queue shows assigned work only.", "rationale": "PRD section 2 settles it.", "citation": {"file": "prd.md", "quote": "The queue shows assigned work only."}}
EOF
: >"$GH_OPS"
rc17=0; run_mirror "$r17" 1100 || rc17=$?
check "T17. the mirror still exits 0 with a Number One journal present" "[ '$rc17' -eq 0 ]"
check "T17. a comment keyed 'number-one' was recorded in the map" \
  "grep -q '\"number-one\"' '$m17/comments.json'"
NOBODY17="$(stage_body "$m17" number-one)"
check "T17. the report names the first officer" \
  "printf '%s' \"\$NOBODY17\" | qgrep -qi 'Number One'"
check "T17. …carries the RECORDED status" \
  "printf '%s' \"\$NOBODY17\" | qgrep -qi 'engaged'"
check "T17. …and the engine it is running on" \
  "printf '%s' \"\$NOBODY17\" | qgrep -q 'copilot'"
check "T17. …the last answer, verbatim" \
  "printf '%s' \"\$NOBODY17\" | qgrep -q 'the queue shows assigned work only'"
check "T17. …with the citation that grounded it (file and quote)" \
  "printf '%s' \"\$NOBODY17\" | qgrep -q 'prd.md' && printf '%s' \"\$NOBODY17\" | qgrep -q 'The queue shows assigned work only'"
check "T17. …and the journal folded into a <details> block" \
  "printf '%s' \"\$NOBODY17\" | qgrep -q '<details>'"
check "T17. the body is NOT the literal sentinel @-" \
  "[ \"\$NOBODY17\" != '@-' ] && [ -n \"\$NOBODY17\" ]"
check "T17. no pricing words in the report" \
  "! printf '%s' \"\$NOBODY17\" | grep -Eqi 'free|billed|billing|pricing'"
NO_CID17="$(sed -n 's/.*"number-one"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$m17/comments.json" | head -1)"

# A SECOND action. THE WHOLE POINT: one more journal line is one more line in
# the SAME comment — an EDIT, never a second comment.
: >"$GH_OPS"
cat >>"$m17/number-one.jsonl" <<'EOF'
{"at": "2026-09-12T11:20:00Z", "action": "answered", "stage": "implement", "answer": "Yes — ship the queue read-only.", "rationale": "ADR-001 settles it.", "citation": {"file": "adr.md", "quote": "The queue is read-only."}}
EOF
run_mirror "$r17" 1200
check "T17. a SECOND action posts NO new Number One comment (no CREATE for it)" \
  "[ -n \"\$NO_CID17\" ] && [ \"\$(sed -n 's/.*\"number-one\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\\1/p' '$m17/comments.json' | head -1)\" = \"\$NO_CID17\" ]"
check "T17. …it EDITED the one that was already there" \
  "grep -q '^EDIT $NO_CID17\$' '$GH_OPS'"
NOBODY17B="$(stage_body "$m17" number-one)"
check "T17. …and the edited body carries BOTH actions" \
  "printf '%s' \"\$NOBODY17B\" | qgrep -q 'assigned work only' && printf '%s' \"\$NOBODY17B\" | qgrep -q 'read-only'"
check "T17. …with the NEWEST answer shown as the last one" \
  "printf '%s' \"\$NOBODY17B\" | qgrep -q 'Yes — ship the queue read-only.'"

# THE ESCALATION. The report is still edited in place, and a NEW comment pings
# the captain — because an edit does not notify, and this gate is now his.
: >"$GH_OPS"
CREATED_BEFORE="$(ls "$GH_BODYDIR" | wc -l | tr -d ' ')"
grep -v '"numberOne"' "$m17/state.json" >"$m17/state.tmp" && mv "$m17/state.tmp" "$m17/state.json"
awk 'NR==1{print; print "  \"numberOne\": {\"status\": \"escalated\", \"engine\": \"copilot\", \"note\": \"the PRD is silent on email — leave it out and file it as a follow-up\"},"; next} {print}' \
  "$m17/state.json" >"$m17/state.tmp" && mv "$m17/state.tmp" "$m17/state.json"
cat >>"$m17/number-one.jsonl" <<'EOF'
{"at": "2026-09-12T12:00:00Z", "action": "escalated", "stage": "implement", "reason": "escalated", "rationale": "The PRD is silent on email.", "recommendation": "Leave email out and file it as a follow-up."}
EOF
run_mirror "$r17" 1300
NOBODY17C="$(stage_body "$m17" number-one)"
check "T17. the escalation is STILL the same comment, edited" \
  "[ -n \"\$NO_CID17\" ] && [ \"\$(sed -n 's/.*\"number-one\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\\1/p' '$m17/comments.json' | head -1)\" = \"\$NO_CID17\" ]"
check "T17. …whose body now carries the escalation note the captain reads" \
  "printf '%s' \"\$NOBODY17C\" | qgrep -q 'file it as a follow-up'"
check "T17. …and a NEW comment was created to PING him (an edit does not notify)" \
  "[ \"\$(ls '$GH_BODYDIR' | wc -l | tr -d ' ')\" -gt '$CREATED_BEFORE' ]"
check "T17. …the ping names Number One so he knows who raised it" \
  "grep -rl 'Number One' '$GH_BODYDIR' | grep -qv '/$NO_CID17\$'"

# IDEMPOTENT. A re-render of the same escalation must NOT ping twice — the S65
# gate-key rule, which this reuses rather than reimplements.
: >"$GH_OPS"
CREATED_NOW="$(ls "$GH_BODYDIR" | wc -l | tr -d ' ')"
run_mirror "$r17" 1400
check "T17. re-rendering the SAME escalation pings nothing a second time" \
  "[ \"\$(ls '$GH_BODYDIR' | wc -l | tr -d ' ')\" = '$CREATED_NOW' ]"

# A mission with NO first officer is byte-for-byte as it was: no key, no comment.
r19="$(new_repo implement)"; make_gh_stub "$r19/gh"; gh_env "$r19"
m19="$(mdir "$r19")"
cat >"$m19/events.jsonl" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
EOF
run_mirror "$r19" 1100
check "T17. a mission Number One never touched grows NO number-one comment" \
  "! grep -q 'number-one' '$m19/comments.json'"

# --- T18 (fix round 1, D2): ONE GATE, ONE NOTIFICATION ----------------------
#
# WHAT WENT WRONG LIVE. A scope park with Number One ON produced TWO comments a
# second apart: the first officer's ping ("Number One handed this gate back to
# you — <note>") AND the generic, contentless one the pipeline has always
# posted. With `lcars xo off` the identical park produced ONE. S202's ping was
# ADDITIONAL to the pre-existing gate ping instead of REPLACING it, so turning
# the first officer on doubled the captain's notifications.
#
# THE CONTROL IS THE POINT. A "one comment" assertion that only ever runs with
# Number One on cannot tell a cure from a mirror that stopped pinging at all, so
# the same gate is driven BOTH ways and the OFF arm's text is asserted verbatim.
#
# PINGS ARE COUNTED, NOT COMMENTS. The first officer's living report is a
# comment too, and it is not a notification — it is created once and edited for
# ever after (T17). What must be exactly one is the 🔔 ping.
pings() { grep -l '🔔 Awaiting your answer' "$GH_BODYDIR"/* 2>/dev/null | wc -l | tr -d ' '; }

GATE_EV='{"ts":1000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
{"ts":1005,"mission":"lcars-20260615-001","stage":"implement","type":"gate","detail":"awaiting your answer"}'

# --- T18a. THE CONTROL: Number One OFF, byte-for-byte as it always was -------
r18a="$(new_repo implement)"; make_gh_stub "$r18a/gh"; gh_env "$r18a"
m18a="$(mdir "$r18a")"
printf '%s\n' "$GATE_EV" >"$m18a/events.jsonl"
run_mirror "$r18a" 1100
check "T18a. CONTROL (xo off): the gate posts EXACTLY ONE ping" \
  "[ \"\$(pings)\" = '1' ]"
PING18A="$(grep -l '🔔 Awaiting your answer' "$GH_BODYDIR"/* 2>/dev/null | head -1)"
check "T18a. …with the pre-existing heading, unchanged" \
  "qgrep -q '^## 🔔 Awaiting your answer\$' <\"\$PING18A\""
check "T18a. …the pre-existing detail line, unchanged" \
  "qgrep -qx 'awaiting your answer' <\"\$PING18A\""
check "T18a. …and the pre-existing reply line, unchanged" \
  "qgrep -q 'Reply with .lcars respond $MID.' <\"\$PING18A\""
check "T18a. …and it says nothing about a first officer" \
  "! qgrep -q 'Number One' <\"\$PING18A\""

# --- T18b. NUMBER ONE ESCALATED: still exactly one ping, and it is HIS -------
r18b="$(new_repo implement)"; make_gh_stub "$r18b/gh"; gh_env "$r18b"
m18b="$(mdir "$r18b")"
awk 'NR==1{print; print "  \"numberOne\": {\"status\": \"escalated\", \"engine\": \"copilot\", \"note\": \"this gate is a scope decision, and scope is yours — leave email out\"},"; next} {print}' \
  "$m18b/state.json" >"$m18b/state.tmp" && mv "$m18b/state.tmp" "$m18b/state.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m18b/state.json" \
  || { echo "T18b FIXTURE IS NOT VALID JSON"; exit 1; }
printf '%s\n' "$GATE_EV" >"$m18b/events.jsonl"
cat >"$m18b/number-one.jsonl" <<'EOF'
{"at": "2026-09-12T12:00:00Z", "action": "escalated", "stage": "implement", "reason": "scope", "recommendation": "Leave email out and file it as a follow-up."}
EOF
run_mirror "$r18b" 1100
check "T18b. Number One ON at the SAME gate still posts EXACTLY ONE ping" \
  "[ \"\$(pings)\" = '1' ]"
PING18B="$(grep -l '🔔 Awaiting your answer' "$GH_BODYDIR"/* 2>/dev/null | head -1)"
check "T18b. …and the one that survived is the one that says WHY" \
  "qgrep -q 'Number One handed this gate back to you' <\"\$PING18B\""
check "T18b. …carrying the note, so the captain is not pinged with nothing" \
  "qgrep -q 'scope is yours' <\"\$PING18B\""
check "T18b. …the generic contentless ping did NOT also fire" \
  "[ \"\$(grep -lx 'awaiting your answer' \"\$GH_BODYDIR\"/* 2>/dev/null | wc -l | tr -d ' ')\" = '0' ]"
check "T18b. the living report is STILL there — a report is not a notification" \
  "grep -q '\"number-one\"' '$m18b/comments.json'"
check "T18b. …and the report is not the ping" \
  "! qgrep -q '🔔' <\"\$(sed -n 's/.*\"number-one\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' '$m18b/comments.json' | head -1 | sed \"s|^|\$GH_BODYDIR/|\")\""
# Idempotent: a re-render of the same escalated gate pings nothing more.
run_mirror "$r18b" 1200
check "T18b. re-rendering the same gate adds no further ping" \
  "[ \"\$(pings)\" = '1' ]"

# --- T18c. ENGAGED BUT NOT ESCALATED: the generic ping MUST still fire -------
# The suppression is "Number One's ping carries this gate", not "Number One is
# on". A first officer holding the conn at a gate it has NOT handed back must
# not silence the notification the captain would otherwise have had.
r18c="$(new_repo implement)"; make_gh_stub "$r18c/gh"; gh_env "$r18c"
m18c="$(mdir "$r18c")"
awk 'NR==1{print; print "  \"numberOne\": {\"status\": \"engaged\", \"engine\": \"copilot\"},"; next} {print}' \
  "$m18c/state.json" >"$m18c/state.tmp" && mv "$m18c/state.tmp" "$m18c/state.json"
printf '%s\n' "$GATE_EV" >"$m18c/events.jsonl"
run_mirror "$r18c" 1100
check "T18c. engaged-but-not-escalated still gets its ONE generic ping" \
  "[ \"\$(pings)\" = '1' ]"
PING18C="$(grep -l '🔔 Awaiting your answer' "$GH_BODYDIR"/* 2>/dev/null | head -1)"
check "T18c. …and it is the pre-existing one, unchanged" \
  "qgrep -qx 'awaiting your answer' <\"\$PING18C\""

# ==========================================================================
echo
printf 'lcars comment-mirror: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
