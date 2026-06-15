#!/usr/bin/env bash
#
# Tests for the issue-comment mirror (ADR-004) — the harness publishes run
# progress onto each Mission's GitHub issue as ordered, human-readable comments
# derived from the EXISTING append-only events.jsonl, idempotently.
#
# The mirror is bundled beside run.sh as skills/lcars-run/comment-mirror.sh and
# is reached through `lcars run mirror-comments --mission <id>`, which:
#   1. reads $MISSION_DIR/events.jsonl line by line, in order,
#   2. for each SURFACED event type, renders ONE human-readable comment body,
#   3. posts it to the Mission's issue via the host adapter's `issue-comment`
#      op (which shells out to $LCARS_GH_BIN issue comment),
#   4. records a `comment_mirrored` marker BACK INTO events.jsonl so a re-run
#      never double-posts. events.jsonl stays the single dedup truth; emit_event
#      and the existing event schema are untouched.
#
# Behaviours under test (each written failing-first against the helper):
#   1. ordered rendering — the gh stub records argv; comments come out IN EVENT
#      ORDER with correctly rendered bodies.
#   2. idempotency — re-running over the SAME events.jsonl posts NO new comments.
#   3. incremental — a newly appended surfaced event posts EXACTLY ONE comment.
#   4. graceful degradation — with $LCARS_GH_BIN failing OR absent, the mirror
#      (and a run that calls it) STILL exits 0.
#
# Dependencies are env-injected so we stub them and assert the call without
# sending anything:
#   LCARS_GH_BIN   the gh binary (default gh) — stubbed to record its argv.
#   LCARS_NOW      unix stamp for the comment_mirrored markers (deterministic).
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
# Drain stdin then grep — safe under set -o pipefail (never SIGPIPE the producer).
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }
# Count matching lines in a file (0 when the file is empty/absent, single token).
countlines() { grep -c "$1" "$2" 2>/dev/null; true; }

MID="lcars-20260615-001"

# A fake `gh` that records every call (one line per invocation) to $GH_LOG, and
# captures `issue comment` bodies (its --body arg) one per line to $GH_BODIES.
make_gh_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
# Capture the body of an `issue comment … --body <text>` call, one per line.
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
  while [ $# -gt 0 ]; do
    if [ "$1" = "--body" ]; then printf '%s\n' "${2:-}" >>"$GH_BODIES"; fi
    if [ "$1" = "--body-file" ]; then cat "${2:-}" >>"$GH_BODIES"; printf '\n' >>"$GH_BODIES"; fi
    shift
  done
fi
exit 0
EOF
  chmod +x "$1"
}

# A fake `gh` that FAILS every call (to prove graceful degradation).
make_gh_failstub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
exit 7
EOF
  chmod +x "$1"
}

# Build an isolated git repo with a mission at "implement" carrying a synthetic
# events.jsonl covering the surfaced set. Returns the repo path on stdout.
new_repo_with_events() { # path-to-events-fixture
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "implement",
  "githubIssue": 42
}
EOF
  cp "$1" "$m/events.jsonl"
  echo "$repo"
}

events_file() { echo "$1/.git/lcars/missions/$MID/events.jsonl"; }

# A synthetic events.jsonl spanning the surfaced types + a couple of noisy
# internal ones the mirror MUST skip (postcommit_ok, ticket_attempt).
write_fixture() { # path
  cat >"$1" <<'EOF'
{"ts":1000,"mission":"lcars-20260615-001","stage":"research","type":"stage_start","detail":"starting"}
{"ts":1001,"mission":"lcars-20260615-001","stage":"research","type":"stage_done","detail":"3 question(s) → findings saved"}
{"ts":1002,"mission":"lcars-20260615-001","stage":"validate","type":"gate","detail":"awaiting your answer"}
{"ts":1003,"mission":"lcars-20260615-001","stage":"implement","type":"wave_start","detail":"wave 1 starting (2 ticket(s))","data":{"wave":1,"count":2}}
{"ts":1004,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_start","detail":"ticket t-001 starting","data":{"ticket":"t-001","wave":1}}
{"ts":1005,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_attempt","detail":"test-writer try 1 for t-001","data":{"ticket":"t-001"}}
{"ts":1006,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_postcommit_ok","detail":"t-001 postcommit ok"}
{"ts":1007,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_green","detail":"ticket t-001 green in 2 attempt(s)","data":{"ticket":"t-001"}}
{"ts":1008,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_flagged","detail":"ticket t-002 flagged after 5 attempt(s)","data":{"ticket":"t-002"}}
EOF
}

mirror() { # repo  [extra env assignments as a prefix string]
  local repo="$1"; shift
  ( cd "$repo" && LCARS_GH_BIN="$repo/gh" LCARS_NOW=2000 "$@" \
      bash "$RUN" mirror-comments --mission "$MID" )
}

# ==========================================================================
echo "lcars comment-mirror"

[ -f "$RUN" ] || { echo "run.sh not found at $RUN"; exit 1; }

FIX="$TMPROOT/events.fixture.jsonl"; write_fixture "$FIX"

# --- Behaviour 1: ordered rendering, correct bodies, surfaced set only ------
repo1="$(new_repo_with_events "$FIX")"; make_gh_stub "$repo1/gh"
export GH_LOG="$repo1/gh.log"; : >"$GH_LOG"
export GH_BODIES="$repo1/gh.bodies"; : >"$GH_BODIES"
rc1=0
( cd "$repo1" && LCARS_GH_BIN="$repo1/gh" LCARS_NOW=2000 \
    bash "$RUN" mirror-comments --mission "$MID" >out.txt 2>&1 ) || rc1=$?
check "1. mirror exits 0" "[ '$rc1' -eq 0 ]"

# It targets the right issue (#42) on every comment call.
check "1. comments are posted to issue #42" \
  "qgrep -q 'issue comment 42' <'$GH_LOG'"
# Exactly the surfaced events become comments — count the issue comment calls.
NCALLS="$(grep -c "issue comment" "$GH_LOG" 2>/dev/null; true)"
# Surfaced: stage_start, stage_done, gate, wave_start, ticket_start,
# ticket_green, ticket_flagged = 7. Skipped: ticket_attempt, postcommit_ok.
check "1. one comment per surfaced event (7), noisy ones skipped" "[ '$NCALLS' -eq 7 ]"

# The noisy internal events never produce a comment body.
check "1. ticket_attempt is NOT surfaced" "! qgrep -qi 'test-writer try' <'$GH_BODIES'"
check "1. postcommit_ok is NOT surfaced"  "! qgrep -qi 'postcommit' <'$GH_BODIES'"

# Bodies are human-readable and carry each event's meaning.
check "1. renders stage start"   "qgrep -qi 'Research' <'$GH_BODIES'"
check "1. renders a raised gate" "qgrep -qi 'awaiting\|needs your\|gate\|answer' <'$GH_BODIES'"
check "1. renders wave progress" "qgrep -qi 'Wave 1' <'$GH_BODIES'"
check "1. renders ticket green"  "qgrep -qi 't-001' <'$GH_BODIES' && qgrep -qi 'green\|passed' <'$GH_BODIES'"
check "1. renders ticket flagged" "qgrep -qi 't-002' <'$GH_BODIES' && qgrep -qi 'flag\|attention\|failed' <'$GH_BODIES'"

# Ordering: the first comment body must correspond to the FIRST surfaced event
# (the research stage_start), not a later one.
FIRST_BODY="$(head -1 "$GH_BODIES")"
check "1. first comment is the first surfaced event (research start)" \
  "printf '%s' \"$FIRST_BODY\" | qgrep -qi 'Research'"

# --- Behaviour 2: idempotency — a second pass posts NOTHING new -------------
: >"$GH_LOG"; : >"$GH_BODIES"
rc2=0
( cd "$repo1" && LCARS_GH_BIN="$repo1/gh" LCARS_NOW=2001 \
    bash "$RUN" mirror-comments --mission "$MID" >out2.txt 2>&1 ) || rc2=$?
check "2. re-run exits 0" "[ '$rc2' -eq 0 ]"
N2="$(grep -c "issue comment" "$GH_LOG" 2>/dev/null; true)"
check "2. re-run over the SAME events posts NO new comments" "[ '$N2' -eq 0 ]"
# The marker type lives in events.jsonl (the single dedup truth), not elsewhere.
check "2. comment_mirrored markers were appended to events.jsonl" \
  "grep -q '\"type\":\"comment_mirrored\"' '$(events_file "$repo1")'"

# --- Behaviour 3: incremental — one new event → exactly one new comment ------
: >"$GH_LOG"; : >"$GH_BODIES"
cat >>"$(events_file "$repo1")" <<'EOF'
{"ts":1009,"mission":"lcars-20260615-001","stage":"implement","type":"stage_done","detail":"all tickets green → verify"}
EOF
rc3=0
( cd "$repo1" && LCARS_GH_BIN="$repo1/gh" LCARS_NOW=2002 \
    bash "$RUN" mirror-comments --mission "$MID" >out3.txt 2>&1 ) || rc3=$?
check "3. incremental run exits 0" "[ '$rc3' -eq 0 ]"
N3="$(grep -c "issue comment" "$GH_LOG" 2>/dev/null; true)"
check "3. a newly appended event posts EXACTLY ONE new comment" "[ '$N3' -eq 1 ]"

# --- Behaviour 4a: gh FAILING → mirror still exits 0 ------------------------
repo4="$(new_repo_with_events "$FIX")"; make_gh_failstub "$repo4/gh"
export GH_LOG="$repo4/gh.log"; : >"$GH_LOG"
rc4=0
( cd "$repo4" && LCARS_GH_BIN="$repo4/gh" LCARS_NOW=2000 \
    bash "$RUN" mirror-comments --mission "$MID" >out.txt 2>&1 ) || rc4=$?
check "4a. mirror exits 0 even when gh FAILS every call" "[ '$rc4' -eq 0 ]"

# --- Behaviour 4b: gh ABSENT → mirror still exits 0 -------------------------
repo4b="$(new_repo_with_events "$FIX")"
export GH_LOG="$repo4b/gh.log"; : >"$GH_LOG"
rc4b=0
( cd "$repo4b" && LCARS_GH_BIN="$repo4b/definitely-not-a-real-binary" LCARS_NOW=2000 \
    bash "$RUN" mirror-comments --mission "$MID" >out.txt 2>&1 ) || rc4b=$?
check "4b. mirror exits 0 even when gh is ABSENT" "[ '$rc4b' -eq 0 ]"

# --- Guard: a mission with no events.jsonl yet is a clean no-op -------------
repo5="$(new_repo_with_events "$FIX")"; make_gh_stub "$repo5/gh"
rm -f "$(events_file "$repo5")"
export GH_LOG="$repo5/gh.log"; : >"$GH_LOG"
rc5=0
( cd "$repo5" && LCARS_GH_BIN="$repo5/gh" LCARS_NOW=2000 \
    bash "$RUN" mirror-comments --mission "$MID" >out.txt 2>&1 ) || rc5=$?
check "guard. no events.jsonl yet → exit 0, no comments" \
  "[ '$rc5' -eq 0 ] && [ ! -s '$GH_LOG' ]"

# --- Guard: a mission with no githubIssue → no-op (nothing to comment on) ----
repo6="$(new_repo_with_events "$FIX")"; make_gh_stub "$repo6/gh"
# Null the issue number.
sed 's/"githubIssue": 42/"githubIssue": null/' \
  "$repo6/.git/lcars/missions/$MID/state.json" >"$repo6/state.tmp" \
  && mv "$repo6/state.tmp" "$repo6/.git/lcars/missions/$MID/state.json"
export GH_LOG="$repo6/gh.log"; : >"$GH_LOG"
rc6=0
( cd "$repo6" && LCARS_GH_BIN="$repo6/gh" LCARS_NOW=2000 \
    bash "$RUN" mirror-comments --mission "$MID" >out.txt 2>&1 ) || rc6=$?
check "guard. no githubIssue → exit 0, posts nothing" \
  "[ '$rc6' -eq 0 ] && ! grep -q 'issue comment' '$GH_LOG'"

# --- Behaviour 5: Stage RE-ENTRY (BUG #185/#186) ----------------------------
# The REAL defect: on a Stage re-entry (mission halts mid-Implement, operator
# re-runs `lcars run <id>`), the harness appends a FRESH stage_start line for
# the SAME stage to events.jsonl — a NEW physical line number, a NEW ts. A
# line-number-keyed dedup treats that new line as never-seen and double-posts a
# BYTE-IDENTICAL "▶️ Implement started". Mirroring MUST be idempotent across
# re-entry (ADR-004, PRD §4): a re-emitted milestone must NEVER double-post,
# while genuinely-distinct events must STILL each post exactly once.
re_repo="$(new_repo_with_events "$FIX")"; make_gh_stub "$re_repo/gh"
export GH_LOG="$re_repo/gh.log"; : >"$GH_LOG"
export GH_BODIES="$re_repo/gh.bodies"; : >"$GH_BODIES"
re_ev="$(events_file "$re_repo")"
# Start the mission's log fresh with a single Implement stage_start (run 1).
cat >"$re_ev" <<'EOF'
{"ts":2000,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
EOF
rcA=0
( cd "$re_repo" && LCARS_GH_BIN="$re_repo/gh" LCARS_NOW=3000 \
    bash "$RUN" mirror-comments --mission "$MID" >outA.txt 2>&1 ) || rcA=$?
check "5. first pass exits 0" "[ '$rcA' -eq 0 ]"
NA="$(grep -c 'issue comment' "$GH_LOG" 2>/dev/null; true)"
check "5. Implement stage_start posts once on first pass" "[ '$NA' -eq 1 ]"

# RE-ENTRY: append a SECOND implement/stage_start for the SAME stage — a NEW
# line number AND a NEW ts, exactly what the harness writes on a re-run. The
# rendered body ('▶️ Implement started') is byte-identical to the first.
: >"$GH_LOG"; : >"$GH_BODIES"
cat >>"$re_ev" <<'EOF'
{"ts":2050,"mission":"lcars-20260615-001","stage":"implement","type":"stage_start","detail":"starting"}
EOF
rcB=0
( cd "$re_repo" && LCARS_GH_BIN="$re_repo/gh" LCARS_NOW=3001 \
    bash "$RUN" mirror-comments --mission "$MID" >outB.txt 2>&1 ) || rcB=$?
check "5. re-entry pass exits 0" "[ '$rcB' -eq 0 ]"
NB="$(grep -c 'issue comment' "$GH_LOG" 2>/dev/null; true)"
check "5. RE-EMITTED identical Implement stage_start does NOT double-post" \
  "[ '$NB' -eq 0 ]"

# stage_done / gate can ALSO re-emit on re-entry (the tester saw a verify/gate
# re-emit). Append a stage_done then RE-EMIT it identically; only ONE comment.
: >"$GH_LOG"; : >"$GH_BODIES"
cat >>"$re_ev" <<'EOF'
{"ts":2100,"mission":"lcars-20260615-001","stage":"verify","type":"stage_done","detail":"all tickets green → verify"}
EOF
rcC=0
( cd "$re_repo" && LCARS_GH_BIN="$re_repo/gh" LCARS_NOW=3002 \
    bash "$RUN" mirror-comments --mission "$MID" >outC.txt 2>&1 ) || rcC=$?
NC="$(grep -c 'issue comment' "$GH_LOG" 2>/dev/null; true)"
check "5. a genuinely-new stage_done posts exactly one comment" "[ '$NC' -eq 1 ]"
: >"$GH_LOG"; : >"$GH_BODIES"
cat >>"$re_ev" <<'EOF'
{"ts":2150,"mission":"lcars-20260615-001","stage":"verify","type":"stage_done","detail":"all tickets green → verify"}
EOF
rcD=0
( cd "$re_repo" && LCARS_GH_BIN="$re_repo/gh" LCARS_NOW=3003 \
    bash "$RUN" mirror-comments --mission "$MID" >outD.txt 2>&1 ) || rcD=$?
ND="$(grep -c 'issue comment' "$GH_LOG" 2>/dev/null; true)"
check "5. RE-EMITTED identical stage_done does NOT double-post" "[ '$ND' -eq 0 ]"

# NOT over-dedup: a genuinely DISTINCT stage_start (a DIFFERENT stage) appended
# after the re-entry collapse must STILL post exactly one new comment.
: >"$GH_LOG"; : >"$GH_BODIES"
cat >>"$re_ev" <<'EOF'
{"ts":2200,"mission":"lcars-20260615-001","stage":"validate","type":"stage_start","detail":"starting"}
EOF
rcE=0
( cd "$re_repo" && LCARS_GH_BIN="$re_repo/gh" LCARS_NOW=3004 \
    bash "$RUN" mirror-comments --mission "$MID" >outE.txt 2>&1 ) || rcE=$?
NE="$(grep -c 'issue comment' "$GH_LOG" 2>/dev/null; true)"
check "5. a DISTINCT stage's stage_start still posts exactly one comment" \
  "[ '$NE' -eq 1 ]"
check "5. the distinct comment is Validate (not over-deduped against Implement)" \
  "qgrep -qi 'Validate' <'$GH_BODIES'"

# NOT over-dedup: two DIFFERENT tickets' ticket_green must each post (their
# bodies differ by ticket id), even though they share a type.
: >"$GH_LOG"; : >"$GH_BODIES"
cat >>"$re_ev" <<'EOF'
{"ts":2300,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_green","detail":"ticket t-010 green in 1 attempt(s)","data":{"ticket":"t-010"}}
{"ts":2301,"mission":"lcars-20260615-001","stage":"implement","type":"ticket_green","detail":"ticket t-011 green in 1 attempt(s)","data":{"ticket":"t-011"}}
EOF
rcF=0
( cd "$re_repo" && LCARS_GH_BIN="$re_repo/gh" LCARS_NOW=3005 \
    bash "$RUN" mirror-comments --mission "$MID" >outF.txt 2>&1 ) || rcF=$?
NF="$(grep -c 'issue comment' "$GH_LOG" 2>/dev/null; true)"
check "5. two DISTINCT tickets' ticket_green each post (no over-dedup)" \
  "[ '$NF' -eq 2 ]"

# ==========================================================================
echo
printf 'lcars comment-mirror: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
