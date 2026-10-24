#!/usr/bin/env bash
#
# S218 — RESEARCH FAILS OUT LOUD, AND THE CAUSE WE FOUND STAYS FIXED.
#
# THE FINDING (S218 diagnosis, reproduced): S214's cold Research worker died
# 6/6 in ~16 s with no log because the code that ran handed copilot the
# mission store's `.git/lcars/context-pack.md` FILE as `--add-dir`. copilot
# 1.0.86 refuses a non-directory at argument parsing (rc=1, "Not a
# directory") — the model never ran. The ~16 s was the hang guard's 15 s poll,
# not a short turn. S213 moved the pack into a directory of its own and made
# the adapter drop any non-directory grant; this suite PINS that end to end.
#
# THE SILENCE is the other half. The adapter threw the worker's exit status
# away (`|| true`) and Research `rm -rf`'d each failed attempt's scratch dir —
# stderr included — so the only thing left was one sentence that named
# neither the status nor the error. Now:
#   • the adapter records `.worker.rc` and a REDACTED `.worker.argv` (the
#     prompt summarised as `<prompt N bytes>`), and keeps its own grant
#     warnings in `.worker.warn` as well as printing them;
#   • before a failed attempt's scratch dir is removed, Research appends that
#     attempt's stderr / exit status / argv / warnings to
#     `$MISSION_DIR/research/worker-failure.log`, one section per attempt;
#   • the stop sentence names the exit status and the log.
#
# Everything is stubbed. The "copilot" here is a self-answering STUB that
# records its argv — nothing named copilot on PATH, no real CLI, no tokens.
#
# Usage: bash tests/lcars-research-failure.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/lcars-run/run.sh"
ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"
STATUS="$REPO_ROOT/skills/lcars-status/status.sh"
PY="${LCARS_PYTHON_BIN:-python3}"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/lcars-rfail.XXXXXX")"
trap "${KEEP_TMP:+:} rm -rf \"\$TMPROOT\"" EXIT

pass=0; fail=0
check() { # <name> <shell-expr>
  if eval "$2" >/dev/null 2>&1; then
    pass=$((pass+1)); printf '  ✓ %s\n' "$1"
  else
    fail=$((fail+1)); printf '  ✗ %s\n' "$1"
  fi
}

MID="lcars-20260918-001-fea3"
SECRET_PHRASE="PRD-BODY-MUST-NOT-LEAK-7731"

# A worker stub. Records every argv (one arg per line, a `---` between calls),
# says $STUB_ERR on stderr, optionally writes questions.txt, exits $STUB_RC.
make_worker() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
{ for a in "$@"; do printf '%s\n' "$a"; done; printf -- '---\n'; } >>"$ARGV_LOG"
[ -n "${STUB_ERR:-}" ] && printf '%s\n' "$STUB_ERR" >&2
if [ "${STUB_WRITE:-}" = 1 ] && [ -n "${LCARS_WORK_OUT:-}" ]; then
  printf '%s\n' "What about X?" >"$LCARS_WORK_OUT/questions.txt"
fi
exit "${STUB_RC:-0}"
EOF
  chmod +x "$1"
}

make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"issue view"*) printf '{"number":1,"title":"t","body":"b","labels":[]}\n' ;;
  *"issue create"*) printf 'https://github.com/o/r/issues/1\n' ;;
  *) printf '\n' ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# A repo with a real mission BRANCH (so Research enters the mission's own
# worktree) and, optionally, a LEGACY context pack FILE at the store root —
# exactly the shape that killed S214.
new_repo() { # [with-pack]
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" \
      && git init -q -b main && git config user.email t@t && git config user.name t \
      && echo hello > README.md && git add README.md && git commit -qm init \
      && git branch "lcars/$MID" ) >/dev/null 2>&1
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  printf '{ "testCommand": "true", "contextSource": "none" }\n' >"$repo/.git/lcars/config.json"
  [ "${1:-}" = with-pack ] && printf '# Context pack\nfacts\n' >"$repo/.git/lcars/context-pack.md"
  printf '# Mission: Editor shell\n**Type:** feature\n**Goal:** %s\n' "$SECRET_PHRASE" >"$m/prd.md"
  cat >"$m/state.json" <<JSON
{
  "id": "$MID",
  "type": "feature",
  "title": "Editor shell",
  "stage": "align",
  "githubIssue": 1,
  "branch": "lcars/$MID",
  "base": "main"
}
JSON
  echo "$repo"
}

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
make_worker "$BIN/worker"; make_gh_stub "$BIN/gh"

run_stage() { # repo subcommand... → $OUT, $RC
  local repo="$1"; shift
  OUT="$( cd "$repo" && env ARGV_LOG="$repo.argv" \
      LCARS_WORKER_BIN="$BIN/worker" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
      LCARS_WORKER_HANG_SECS=0 LCARS_NOTIFY=true \
      LCARS_WORKER_ADAPTER="${ADAPTER_OVERRIDE:-$ADAPTER}" \
      bash "$SCRIPT" "$@" 2>&1 )"
  RC=$?
}

# =========================================================================
printf '\n  -- 1. a worker that exits 1 with stderr leaves a durable record --\n'
R1="$(new_repo)"
STUB_RC=1 STUB_ERR="error: option '--add-dir <directory>' argument is invalid. Not a directory" \
  LCARS_WORKER_TRIES=3 run_stage "$R1" research --mission "$MID"
LOG1="$R1/.git/lcars/missions/$MID/research/worker-failure.log"
check "1a. Research stopped (non-zero)" "[ $RC -ne 0 ]"
check "1b. research/worker-failure.log exists in the mission dir" "[ -s '$LOG1' ]"
check "1c. …with the worker's own stderr" "grep -qF 'Not a directory' '$LOG1'"
check "1d. …and its exit status" "grep -qE 'exit status: 1\$' '$LOG1'"
check "1e. one section per attempt (3 attempts → 3 sections)" \
  "[ \"\$(grep -c '^=== attempt ' '$LOG1')\" = 3 ]"
check "1f. each section is timestamped" \
  "[ \"\$(grep -cE '^=== attempt [0-9]+ of [0-9]+ .*[0-9]{4}-[0-9]{2}-[0-9]{2}T' '$LOG1')\" = 3 ]"
check "1g. the argv is recorded, prompt summarised as <prompt N bytes>" \
  "grep -qE -- '-p <prompt [0-9]+ bytes>' '$LOG1' && grep -qF -- '--available-tools' '$LOG1'"
check "1h. the prompt itself never reaches the log" "! grep -qF '$SECRET_PHRASE' '$LOG1'"
check "1i. the stop sentence names the exit status" \
  "printf '%s' \"\$OUT\" | grep -q 'exited 1'"
check "1j. …and the log, by its path under the mission" \
  "printf '%s' \"\$OUT\" | grep -qF '.git/lcars/missions/$MID/research/worker-failure.log'"
check "1k. the old words stay, so every surface that keys on them still matches" \
  "printf '%s' \"\$OUT\" | grep -q 'produced no questions.txt after 3 attempt(s)'"

# =========================================================================
printf '\n  -- 2. the card and lcars status say it whole, and say Research --\n'
R2="$(new_repo)"
STUB_RC=1 STUB_ERR="boom from the worker" LCARS_WORKER_TRIES=1 run_stage "$R2" drive --mission "$MID"
OUT2="$OUT"
EV2="$R2/.git/lcars/missions/$MID/events.jsonl"
ERRLINE="$(grep '"type": *"error"' "$EV2" 2>/dev/null | tail -1)"
# (Parsed as JSON: since S218 fix round 1 the line carries a trailing "data".)
DETAIL="$(printf '%s' "$ERRLINE" | "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read())["detail"])' 2>/dev/null)"
printf '    the captain would read: ✖ %s\n' "$DETAIL"
check "2a. the event names research, not align" "printf '%s' \"\$DETAIL\" | grep -q '^research failed: ' && ! printf '%s' \"\$DETAIL\" | grep -qi 'align'"
check "2b. the sentence names the exit status and the log" \
  "printf '%s' \"\$DETAIL\" | grep -q 'exited 1' && printf '%s' \"\$DETAIL\" | grep -qF 'research/worker-failure.log'"
check "2c. …and runs whole to its end" "printf '%s' \"\$DETAIL\" | grep -q 'Stage stopped, no advance.\$'"
BOARD="$(cd "$REPO_ROOT/web" && "$PY" -c '
import json, sys
from lcars_serve.local_adapter import LocalAdapter
print(json.dumps(LocalAdapter(sys.argv[1], read_only=True).mission(sys.argv[2])))' "$R2" "$MID" 2>&1)"
check "2d. the card's detail feed (the board payload) carries the whole sentence" \
  "printf '%s' \"\$BOARD\" | grep -qF 'research/worker-failure.log. Stage stopped, no advance.'"
ST="$(cd "$R2" && LCARS_GH_BIN="$BIN/gh" bash "$STATUS" --once "$MID" 2>&1)"
check "2e. lcars status carries the whole sentence" \
  "printf '%s' \"\$ST\" | grep -qF 'research/worker-failure.log. Stage stopped, no advance.'"

# =========================================================================
printf '\n  -- 3. exit 0 with no output is a failure, and is logged as one --\n'
R3="$(new_repo)"
STUB_RC=0 STUB_ERR="" LCARS_WORKER_TRIES=2 run_stage "$R3" research --mission "$MID"
LOG3="$R3/.git/lcars/missions/$MID/research/worker-failure.log"
check "3a. Research stopped (non-zero) — not a silent pass" "[ $RC -ne 0 ]"
check "3b. the empty attempts are logged, one section each" \
  "[ \"\$(grep -c '^=== attempt ' '$LOG3')\" = 2 ]"
check "3c. …with exit status 0, and what was missing" \
  "grep -qE 'exit status: 0\$' '$LOG3' && grep -qF 'questions.txt' '$LOG3'"
check "3d. the stop sentence says it exited 0" "printf '%s' \"\$OUT\" | grep -q 'exited 0'"

# =========================================================================
printf '\n  -- 4. THE CAUSE, PINNED: a context-pack FILE is never an --add-dir --\n'
R4="$(new_repo with-pack)"
STUB_RC=1 STUB_ERR="x" LCARS_WORKER_TRIES=1 run_stage "$R4" research --mission "$MID"
ARGS4="$R4.argv"
check "4a. the worker was spawned (argv recorded)" "[ -s '$ARGS4' ]"
# The FIRST --add-dir of each call is the attempt's own scratch outdir (gone
# by now — Research removes it); every grant AFTER it is an input grant.
input_grants() { awk '$0=="---"{n=0; next} p{if (n>1) print; p=0} $0=="--add-dir"{n++; p=1}' "$1"; }
check "4a'. the pack's directory was granted as an input (so it is really exercised)" \
  "input_grants '$ARGS4' | grep -q '/.git/lcars/context\$'"
bad_grant="$(input_grants "$ARGS4" | while IFS= read -r d; do [ -d "$d" ] || echo "$d"; done)"
check "4b. every --add-dir names a DIRECTORY ${bad_grant:+(not: $bad_grant)}" "[ -z \"\$bad_grant\" ]"
check "4c. no --add-dir names context-pack.md" "! awk 'p{print; p=0} \$0==\"--add-dir\"{p=1}' '$ARGS4' | grep -q 'context-pack.md'"
check "4d. the store root (every mission's state) is never granted" \
  "! awk 'p{print; p=0} \$0==\"--add-dir\"{p=1}' '$ARGS4' | grep -qxF \"\$(cd '$R4/.git/lcars' && pwd -P)\" && ! awk 'p{print; p=0} \$0==\"--add-dir\"{p=1}' '$ARGS4' | grep -qxF '$R4/.git/lcars'"
check "4e. the legacy pack moved into a directory of its own" \
  "[ -f '$R4/.git/lcars/context/context-pack.md' ] && [ ! -e '$R4/.git/lcars/context-pack.md' ]"

# =========================================================================
printf '\n  -- 5. the adapter'"'"'s not-a-directory warning reaches the stage and its log --\n'
# Reproduce the ORIGINAL defect's grant: a wrapper hands the real adapter the
# pack FILE as an input "dir" — what main's worker_input_dirs did.
R5="$(new_repo)"
PACKFILE="$TMPROOT/stale-context-pack.md"; printf 'x\n' >"$PACKFILE"
cat >"$BIN/adapter-with-file-grant" <<EOF
#!/usr/bin/env bash
export LCARS_WORKER_INPUT_DIRS="\${LCARS_WORKER_INPUT_DIRS:-}
$PACKFILE"
exec bash "$ADAPTER" "\$@"
EOF
chmod +x "$BIN/adapter-with-file-grant"
ADAPTER_OVERRIDE="$BIN/adapter-with-file-grant" STUB_RC=1 STUB_ERR="x" LCARS_WORKER_TRIES=1 \
  run_stage "$R5" research --mission "$MID"
LOG5="$R5/.git/lcars/missions/$MID/research/worker-failure.log"
check "5a. the warning is in the stage's output" \
  "printf '%s' \"\$OUT\" | grep -qF \"NOT granting $PACKFILE\""
check "5b. …and in research/worker-failure.log" "grep -qF \"NOT granting $PACKFILE\" '$LOG5'"
check "5c. …and the file was still not handed to --add-dir" "! grep -qxF '$PACKFILE' '$R5.argv'"

# =========================================================================
printf '\n  -- 6. the adapter itself records rc + redacted argv (the shared seam) --\n'
OD="$TMPROOT/od6"
( ARGV_LOG="$TMPROOT/od6.argv" STUB_RC=7 STUB_ERR="seven" LCARS_WORKER_BIN="$BIN/worker" \
    bash "$ADAPTER" spawn copilot repo-read "$OD" "a secret prompt $SECRET_PHRASE" ) >/dev/null 2>&1; arc=$?
check "6a. spawn still never fails its caller (|| true semantics)" "[ $arc -eq 0 ]"
check "6b. .worker.rc holds the worker's exit status" "[ \"\$(cat '$OD/.worker.rc')\" = 7 ]"
check "6c. .worker.argv is written, prompt summarised" \
  "grep -qE -- '-p <prompt [0-9]+ bytes>' '$OD/.worker.argv' && ! grep -qF '$SECRET_PHRASE' '$OD/.worker.argv'"
check "6d. an exit-0 run records 0" \
  "( ARGV_LOG=/dev/null STUB_RC=0 LCARS_WORKER_BIN='$BIN/worker' bash '$ADAPTER' spawn copilot repo-read '$TMPROOT/od6b' p ) >/dev/null 2>&1 && [ \"\$(cat '$TMPROOT/od6b/.worker.rc')\" = 0 ]"
check "6e. the empty-worker detector still reads the new capture files as NOT output" \
  "mkdir -p '$TMPROOT/od6c' && : >'$TMPROOT/od6c/.worker.out' && : >'$TMPROOT/od6c/.worker.err' && echo 0 >'$TMPROOT/od6c/.worker.rc' && echo x >'$TMPROOT/od6c/.worker.argv' && LCARS_TEST_OUTDIR='$TMPROOT/od6c' bash '$SCRIPT' worker-empty-detect-test"

# =========================================================================
printf '\n  -- 7. the failure is RECORDED as a fact the card and the table read --\n'
# (S218 fix round 1, F1/F2.) R2's drive above failed Research for real.
check "7a. the error event records the log path as data, not only in prose" \
  "printf '%s' \"\$ERRLINE\" | grep -qF '\"data\":{\"stageFailure\":1,\"log\":\".git/lcars/missions/$MID/research/worker-failure.log\"}'"
CARD2="$(cd "$REPO_ROOT/web" && "$PY" -c '
import json, sys
from lcars_serve.local_adapter import LocalAdapter
b = LocalAdapter(sys.argv[1], read_only=True).board()
c = [m for m in b["missions"] if m["id"] == sys.argv[2]][0]
print(json.dumps({"stage": c["stage"], "failure": c.get("failure")}))' "$R2" "$MID" 2>&1)"
check "7b. /api/board's card carries failure.stage = research" \
  "printf '%s' \"\$CARD2\" | grep -qF '\"failure\": {\"stage\": \"research\"'"
check "7c. …and the card is NOT moved (stage from the label: align)" \
  "printf '%s' \"\$CARD2\" | grep -qF '{\"stage\": \"align\"'"
TBL="$(cd "$R2" && LCARS_GH_BIN="$BIN/gh" bash "$STATUS" 2>&1)"
printf '%s\n' "$TBL" | sed 's/^/    | /'
check "7d. plain lcars status marks the row as failed (✖), stage cell unchanged" \
  "printf '%s' \"\$TBL\" | grep -E '^$MID .*align +✖' >/dev/null"
check "7e. …and says Research failed, pointing at the log and --once" \
  "printf '%s' \"\$TBL\" | grep -F 'Research failed' | grep -qF 'research/worker-failure.log' && printf '%s' \"\$TBL\" | grep -qF -- '--once $MID'"
# A later successful Stage (or a new run starting) clears it — on both surfaces.
( cd "$R2" && bash "$SCRIPT" emit-event --mission "$MID" --type stage_start --stage research --detail starting \
  && bash "$SCRIPT" emit-event --mission "$MID" --type stage_done --stage research --detail done ) >/dev/null 2>&1
CARD2b="$(cd "$REPO_ROOT/web" && "$PY" -c '
import json, sys
from lcars_serve.local_adapter import LocalAdapter
b = LocalAdapter(sys.argv[1], read_only=True).board()
c = [m for m in b["missions"] if m["id"] == sys.argv[2]][0]
print(json.dumps({"failure": c.get("failure")}))' "$R2" "$MID" 2>&1)"
check "7f. after a successful Research the card carries no failure" \
  "printf '%s' \"\$CARD2b\" | grep -qF '{\"failure\": null}'"
TBL2="$(cd "$R2" && LCARS_GH_BIN="$BIN/gh" bash "$STATUS" 2>&1)"
check "7g. …and lcars status no longer says it failed" \
  "! printf '%s' \"\$TBL2\" | grep -q 'failed' && ! printf '%s' \"\$TBL2\" | grep -q '✖'"

# =========================================================================
printf '\n  -- 8. a drive with no failure log yet prints no "No such file" (D1) --\n'
# (S218 fix round 2, D1.) The before/after size read of worker-failure.log used
# `wc -c <file 2>/dev/null`: the `<` fails before the 2>/dev/null applies, so
# EVERY drive of a Stage with no log yet printed a bash error on stderr.
R8="$(new_repo)"
ERR8="$TMPROOT/r8.err"
( cd "$R8" && env ARGV_LOG="$R8.argv" \
    LCARS_WORKER_BIN="$BIN/worker" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN="$BIN/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_WORKER_HANG_SECS=0 LCARS_NOTIFY=true LCARS_WORKER_ADAPTER="$ADAPTER" \
    STUB_RC=0 STUB_WRITE=1 STUB_ERR="" LCARS_WORKER_TRIES=1 \
    bash "$SCRIPT" drive --step --mission "$MID" ) >/dev/null 2>"$ERR8"
sed 's/^/    stderr| /' "$ERR8" | head -5
check "8a. a healthy drive's stderr has no 'No such file'" "! grep -q 'No such file' '$ERR8'"
check "8b. …and the failing drive (R2) printed none either" \
  "! printf '%s' \"\$OUT2\" | grep -q 'No such file'"

# =========================================================================
printf '\n  -- 9. an UNMARKED (pre-S214) error event is never surfaced (D2) --\n'
# The captain's real history holds `error` events recorded against `align` with
# a sentence beheaded mid-word. Only an event the drive marked as a structured
# Stage failure (data.stageFailure) reaches the card / detail / status.
R9="$(new_repo)"
printf '%s\n' '{"ts":500,"mission":"'"$MID"'","stage":"align","type":"error","detail":"align failed: ars-20260918-001-fea3'"'"' @ fd4e952 (the worker exited 1)"}' \
  >"$R9/.git/lcars/missions/$MID/events.jsonl"
TBL9="$(cd "$R9" && LCARS_GH_BIN="$BIN/gh" bash "$STATUS" 2>&1)"
check "9a. lcars status: no ✖ and no 'failed' footer for a legacy align error" \
  "! printf '%s' \"\$TBL9\" | grep -q '✖' && ! printf '%s' \"\$TBL9\" | grep -q 'Stopped on a failure'"
CARD9="$(cd "$REPO_ROOT/web" && "$PY" -c '
import json, sys
from lcars_serve.local_adapter import LocalAdapter
b = LocalAdapter(sys.argv[1], read_only=True).board()
c = [m for m in b["missions"] if m["id"] == sys.argv[2]][0]
print(json.dumps({"failure": c.get("failure")}))' "$R9" "$MID" 2>&1)"
check "9b. the card carries no failure for it" "printf '%s' \"\$CARD9\" | grep -qF '{\"failure\": null}'"
printf '%s\n' '{"ts":600,"mission":"'"$MID"'","stage":"research","type":"error","detail":"research failed: boom","data":{"stageFailure":1}}' \
  >>"$R9/.git/lcars/missions/$MID/events.jsonl"
TBL9b="$(cd "$R9" && LCARS_GH_BIN="$BIN/gh" bash "$STATUS" 2>&1)"
check "9c. a MARKED research error after it is surfaced by lcars status" \
  "printf '%s' \"\$TBL9b\" | grep -E '^$MID .*align +✖' >/dev/null && printf '%s' \"\$TBL9b\" | grep -q 'Research failed'"

# =========================================================================
printf '\n  -- 10. S312: "FAILED AND IDLE" READS DIFFERENTLY FROM IN-FLIGHT --\n'
# =========================================================================
# THE 4h49m MISSION. Section 9 proves the EVENT-LOG half (S218). This is the
# MISSION-STATE half: the mission that sat dead for 4 hours 49 minutes had
# `"stage": "implement"` in state.json and nothing else, and every reader that
# asks mission state "how is this mission?" — the ECH, the heartbeat, the
# hourly line — got the same answer as for healthy work. S312 records the fact
# where those readers look (failedStage/failedAt/failedReason, beside
# awaitingHuman) and both surfaces now read it.
#
# THE CONTROL IS THE POINT OF THIS SECTION. Each check below is paired with the
# SAME mission in the healthy shape, so a pass means "these two render
# differently" and not merely "the failed one rendered something".

# --- the HEALTHY control: an in-flight mission, nothing recorded as failed.
R10="$(new_repo)"
TBL10h="$(cd "$R10" && LCARS_GH_BIN="$BIN/gh" bash "$STATUS" 2>&1)"
check "10a. CONTROL — a healthy mission carries no ✖ and no failure footer" \
  "! printf '%s' \"\$TBL10h\" | grep -q '✖' && ! printf '%s' \"\$TBL10h\" | grep -q 'Stopped on a failure'"

# --- the FAILED one: the same mission, with S312's recorded fact and NOTHING
#     in events.jsonl at all. That is the real shape — the driver exited
#     normally and the mission simply stopped being advanced.
"$PY" - "$R10/.git/lcars/missions/$MID/state.json" <<'PY10'
import json, sys
d = json.load(open(sys.argv[1]))
d["stage"] = "implement"
d["failedStage"] = "implement"
d["failedAt"] = "2026-10-23T01:36:00Z"
d["failedReason"] = "implement failed: the self-heal round could not apply its fix"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY10
check "10-setup. there is no events.jsonl for this mission at all" \
  "[ ! -f '$R10/.git/lcars/missions/$MID/events.jsonl' ]"
TBL10="$(cd "$R10" && LCARS_GH_BIN="$BIN/gh" bash "$STATUS" 2>&1)"
check "10b. the row carries the ✖ failed glyph" \
  "printf '%s' \"\$TBL10\" | grep -qE '^$MID .*✖'"
check "10c. …and the legend explains it, so one line is readable on its own" \
  "printf '%s' \"\$TBL10\" | grep -q '✖ stage failed'"
check "10d. the footer names it as stopped on a failure" \
  "printf '%s' \"\$TBL10\" | grep -q 'Stopped on a failure'"
check "10e. …names the STAGE that failed" \
  "printf '%s' \"\$TBL10\" | grep -q 'Implement failed'"
check "10f. …and prints the recorded REASON, whole (the awaiting-human precedent)" \
  "printf '%s' \"\$TBL10\" | grep -q 'could not apply its fix'"
# AND THE TWO RENDERINGS ARE GENUINELY DIFFERENT — asserted directly, because
# "it printed something" is not the behaviour; "a human can tell them apart" is.
check "10g. the failed rendering DIFFERS from the healthy one" \
  "[ \"\$TBL10\" != \"\$TBL10h\" ]"

# --- a LIVE driver means a new run is under way, so the last failure is not
#     the news. Same state, a real live lock holder.
( exec -a lcars-fake-driver sh -c 'while :; do sleep 1; done' ) </dev/null >/dev/null 2>&1 &
live10=$!
mkdir -p "$R10/.git/lcars/missions/$MID/driver.lock"
printf '%s\n' "$live10" >"$R10/.git/lcars/missions/$MID/driver.lock/pid"
TBL10L="$(cd "$R10" && LCARS_GH_BIN="$BIN/gh" bash "$STATUS" 2>&1)"
check "10h. a mission with a LIVE driver is NOT shown as failed (it is working)" \
  "! printf '%s' \"\$TBL10L\" | grep -q 'Stopped on a failure'"
kill -9 "$live10" 2>/dev/null; wait "$live10" 2>/dev/null || true
rm -rf "$R10/.git/lcars/missions/$MID/driver.lock"

# --- THE BOARD API half of behaviour 3: the card carries the failure read from
#     state.json, in the SAME `failure` shape the front end already renders.
CARD10="$(cd "$REPO_ROOT/web" && "$PY" -c '
import json, sys
from lcars_serve.local_adapter import LocalAdapter
b = LocalAdapter(sys.argv[1], read_only=True).board()
c = [m for m in b["missions"] if m["id"] == sys.argv[2]][0]
print(json.dumps(c.get("failure")))' "$R10" "$MID" 2>&1)"
check "10i. the board card carries a failure object from state.json" \
  "printf '%s' \"\$CARD10\" | grep -q '\"stage\": \"implement\"'"
check "10j. …carrying the recorded sentence" \
  "printf '%s' \"\$CARD10\" | grep -q 'could not apply its fix'"
CARD10h="$(cd "$REPO_ROOT/web" && "$PY" -c '
import json, sys
from lcars_serve.local_adapter import LocalAdapter
b = LocalAdapter(sys.argv[1], read_only=True).board()
c = [m for m in b["missions"] if m["id"] == sys.argv[2]][0]
print(json.dumps(c.get("failure")))' "$(new_repo)" "$MID" 2>&1)"
check "10k. CONTROL — a healthy mission's card carries NO failure" \
  "printf '%s' \"\$CARD10h\" | grep -qx 'null'"

echo
printf 'lcars research failure: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
