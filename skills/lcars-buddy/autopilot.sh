#!/usr/bin/env bash
#
# autopilot.sh — the TOKEN-FREE driver behind `lcars buddy`'s autopilot mode
# ("run it for me"). The judgement in that mode is prose the MODEL follows
# (AUTOPILOT.md); everything SEQUENCEABLE is here, and spends nothing.
#
# IT DRIVES THE EXISTING VERBS. Every action below is an LCARS verb that an
# earlier round already proved: `run.sh drive --mission`, `approve.sh
# --mission`, `respond.sh answer`, `log.sh --parent --prd`,
# `resolve-logs.sh --parent`, `xo.sh off`, `file.sh --prd --engine`. This script
# re-implements NONE of them — no stage order, no gate detection, no PR
# handling, no merge. A gate LCARS refuses becomes a written question for the
# captain, never a second route to the same outcome.
#
# WHY A SCRIPT AT ALL. Over 26–29 Sep 2026 a model ran this mode by hand for
# ~36 hours and lost real time to re-inventing the same shell badly: a
# "suite then push" gate that matched `FAILED` as success and pushed a red
# `main`, and an `alarm` wrapper that killed `approve` mid-retest. Those are now
# `push-gated` and `drive`'s process waiter, with tests. A guard that lives only
# in prose gets re-invented by the next session.
#
# RECORD, DON'T INFER. Every fact the mode needs later is WRITTEN to
# `.git/lcars/autopilot.json` at the moment it is decided — scope, latitude,
# the captain's answers, the captain-only steps, driver pids, the one open
# question. Nothing is reconstructed from a chat transcript or scraped back out
# of a log: a recorded pid is a measurement, log text is a heuristic over prose
# a human also writes. `stalled` (what the heartbeat calls) decides purely from
# recorded pids for exactly that reason.
#
#   autopilot.sh init --spec <path|url> [--scope M0,M1] [--engine copilot]
#                     [--deadline <iso>] [--force]
#   autopilot.sh status
#   autopilot.sh next [--all]
#   autopilot.sh drive <mission>
#   autopilot.sh stalled
#   autopilot.sh land <mission>
#   autopilot.sh push-gated
#   autopilot.sh worktree <mission>
#   autopilot.sh ledger feedback|overrides|decisions '<json>'
#   autopilot.sh heartbeat install|remove|status
#   autopilot.sh record <dotted.key> <value>
#   autopilot.sh answered <question-id|mission> ["<his answer>"]
#   autopilot.sh playbook
#
# EXIT CODES that mean something:
#   0   done
#   10  a question for the CAPTAIN was written to autopilot.json.pending and the
#       milestone stopped. This is the ONLY response to a refused merge.
#   11  the driver refused a mechanical pre-check (e.g. a live drive on the same
#       mission). Not a captain question — fix it and retry.
#   1   usage / a bad argument.
#
# DEPENDENCIES ARE ENV-INJECTED (the lcars-init pattern) so tests stub them:
#   LCARS_AUTOPILOT_CWD   the repo to operate on       (default $PWD)
#   LCARS_GIT_BIN         git                          (default git)
#   LCARS_PYTHON_BIN      python3                      (default python3)
#   LCARS_CRONTAB_BIN     crontab                      (default crontab)
#   LCARS_RUN_SCRIPT LCARS_APPROVE_SCRIPT LCARS_XO_SCRIPT LCARS_RESPOND_SCRIPT
#   LCARS_LOG_SCRIPT LCARS_FILE_SCRIPT LCARS_RESOLVE_LOGS_SCRIPT
#   LCARS_ESTABLISH_VISION_BIN                         (sibling skills)
#   LCARS_NOTIFY          the walk-away ping           (lcars-run/notify.sh)
#
# BASH 3.2 ONLY. macOS ships 3.2.57 and this runs on the captain's laptop, so
# nothing from bash 4 may appear here: no associative arrays, no line-slurping
# array builtin, no case-folding parameter expansion. There is also no
# `timeout` and no coreutils on that box — `timeout 300 …` silently becomes
# "command not found" — which is the other reason the waiter watches a process
# rather than a clock.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
SKILLS_DIR="$(cd "$SELF_DIR/.." && pwd)"

GIT_BIN="${LCARS_GIT_BIN:-git}"
PY="${LCARS_PYTHON_BIN:-python3}"
CRONTAB_BIN="${LCARS_CRONTAB_BIN:-crontab}"

RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SKILLS_DIR/lcars-run/run.sh}"
APPROVE_SCRIPT="${LCARS_APPROVE_SCRIPT:-$SKILLS_DIR/lcars-approve/approve.sh}"
XO_SCRIPT="${LCARS_XO_SCRIPT:-$SKILLS_DIR/lcars-xo/xo.sh}"
RESPOND_SCRIPT="${LCARS_RESPOND_SCRIPT:-$SKILLS_DIR/lcars-respond/respond.sh}"
NOTIFY_BIN="${LCARS_NOTIFY:-$SKILLS_DIR/lcars-run/notify.sh}"

die()  { printf 'lcars autopilot: %s\n' "$1" >&2; exit "${2:-1}"; }
say()  { printf '%s\n' "$1"; }

# The cheat sheet. The modelled run's two biggest token sinks were reading LCARS
# internals to find a verb's real flags, and long log greps. Both are answered
# here, on purpose, so nobody has to go and read run.sh to drive a mission.
usage() {
  cat >&2 <<USAGE
Usage: autopilot.sh <subcommand> [args]        (playbook: AUTOPILOT.md, beside this script)

  init --spec <path|url> [--scope M0,M1] [--engine <e>] [--deadline <iso>] [--force]
                       write .git/lcars/autopilot.json (refuses to overwrite without --force)
  status               one screen: scope, stages, gates, slots, EVERY open question, next action
  next [--all]         the ONE next mechanical step, and the AUTOPILOT.md heading for it
  playbook             the action -> heading table the contract test locks
  record <k.k> <v>     write one key (JSON value if it parses; empty value deletes)
  answered <id> "<a>"  close ONE open question (ids come from \`status\`); never deletes it

  drive <mission>      run.sh drive --mission, backgrounded, waiter on the PROCESS
  stalled              what the crontab heartbeat calls; decides from recorded pids
  land <mission>       approve.sh --mission + hygiene; exit 10 = a question was written
  push-gated           run the recorded testCommand, push ONLY on exit 0
  worktree <mission>   git worktree add --detach + a throwaway HOME; prints both
  ledger feedback|overrides|decisions '<json>'
  heartbeat install|remove|status

THE TWO CAPS THIS DRIVER ENFORCES: two parallel missions, and three failed
drives of the same mission (then it asks the captain instead of retrying).

THE VERBS THIS DRIVES (their real flags — do not guess, and do not re-implement):
  lcars-file/file.sh            --prd <path> --engine <e> [--idea <path>] [--park]
  lcars-init/establish-vision.sh --file --stack <s> --slice <s> --engine <e>
  lcars-run/run.sh              drive --mission <id> [--step]   (env: LCARS_GATE_TIMEOUT)
  lcars-log/log.sh              --parent <id> --prd <file> [--prd <file> …]
  lcars-resolve-logs/…          --parent <id> [--bug <id>]
  lcars-respond/respond.sh      list | show --mission <id> | answer --mission <id> --answer "<t>"
  lcars-approve/approve.sh      --mission <id>
  lcars-xo/xo.sh                on | off <mission> | status | report

EXIT CODES: 0 ok | 10 a question for the captain was written to .pending | 11 pre-check
            refused (not a captain question) | 1 usage.
USAGE
  exit 1
}

# --- where we are ---------------------------------------------------------
CWD="${LCARS_AUTOPILOT_CWD:-$PWD}"
[ -d "$CWD" ] || die "no such directory: $CWD"
CWD="$(cd "$CWD" && pwd)"
GITDIR="$CWD/.git"
[ -e "$GITDIR" ] || die "$CWD is not a git repository — the autopilot operates on a repo."
LCARS_DIR="$GITDIR/lcars"
MISSIONS="$LCARS_DIR/missions"
CFG="$LCARS_DIR/config.json"
APJSON="$LCARS_DIR/autopilot.json"
APDIR="$LCARS_DIR/autopilot"
LOCKDIR="$LCARS_DIR/autopilot.json.lock"

# The parallelism ceiling. Two concurrent missions was the measured safe maximum
# on a 10-core Mac; three drove load average to 170 and killed workers.
MAX_SLOTS=2

# THE DRIVE FAILURE CAP. A drive that keeps failing used to be offered again by
# `next` for ever: `drivers.<m>.exitCode` was written and then only PRINTED, and
# it was overwritten on each attempt so even the failure count was lost. Three
# consecutive failing drives of the same mission each produced
# `NEXT: drive lcars-…`, so an unattended overnight run would spin on one broken
# stage until morning, achieve nothing, and never tell the captain. The count is
# now RECORDED (`drivers.<m>.failures`, not re-derived) and capped here; hitting
# the cap escalates to a pre-staged question under the mode's own stop-and-ask
# category, "an LCARS bug with no verb workaround". A clean drive clears it, so
# one flake never poisons a mission.
MAX_DRIVE_FAILURES=3

# ==========================================================================
# JSON — read and write, via python3 (already an LCARS harness dependency).
# Hand-rolled awk readers are fine for flat config files; autopilot.json is a
# NESTED record that this script also WRITES, and a half-written state file is
# exactly the "inferred, not recorded" failure the mode exists to avoid.
# ==========================================================================

# jfile <file> <dotted.path> → the scalar, or "" (absent, null and "" all read
# as empty; call sites that care test the key's presence separately).
jfile() {
  [ -f "$1" ] || return 0
  "$PY" - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
cur = d
for part in sys.argv[2].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(0)
if cur is None:
    sys.exit(0)
sys.stdout.write(cur if isinstance(cur, str) else json.dumps(cur))
PY
}

ap_j() { jfile "$APJSON" "$1"; }

# jkeys <file> <dotted.path> → the object's keys, one per line, insertion order.
jkeys() {
  [ -f "$1" ] || return 0
  "$PY" - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
cur = d
if sys.argv[2]:
    for part in sys.argv[2].split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            sys.exit(0)
if isinstance(cur, dict):
    for k in cur:
        print(k)
elif isinstance(cur, list):
    for k in cur:
        print(k if isinstance(k, str) else json.dumps(k))
PY
}

ap_keys() { jkeys "$APJSON" "$1"; }

# open_questions → "id<TAB>mission<TAB>what", one per UNANSWERED question,
# oldest first.
#
# WHY A LEDGER AND NOT ONE SLOT. `.pending` was a single object that every new
# question OVERWROTE, so a second question silently DELETED the first: the
# captain answered the one he could see and never learned the other existed.
# That is precisely the "record, don't infer" failure this mode exists to
# prevent. `questions` is now the durable record — append-only, nothing
# destroyed on write — and `.pending` is a derived MIRROR of the oldest open
# one, kept because the model-facing surface reads a single question.
#
# A hand-written `.pending` (AUTOPILOT.md § 9 tells the model to write that
# shape for anything `land` does not cover) with no `questions` entry still
# counts as one open question, so nothing the model records by hand is lost.
open_questions() {
  [ -f "$APJSON" ] || return 0
  "$PY" - "$APJSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
def flat(v):
    return (v or "").replace("\t", " ").replace("\n", " ")
qs = [q for q in (d.get("questions") or {}).values()
      if isinstance(q, dict) and not q.get("answeredAt")]
# ALONGSIDE, NOT INSTEAD OF. This used to be `if not qs:` - the hand-written
# `.pending` was shown ONLY when the ledger had nothing open, so one ordinary
# open question MASKED it: zero rows here, zero rows in `next`, and the count
# read 1 while two were open. Those are exactly the questions that must reach
# the captain (a product call, a scope change, a standing-rule conflict), and
# it masked precisely when the autopilot was busiest.
# DEDUPED ON (mission, what) - the same key the raise and adoption paths use -
# because `.pending` is also the MIRROR of the oldest open question: once it has
# been adopted, the adopted copy and the raw pending are ONE question and must
# print once. The dedupe is over the OPEN set only, so a recurrence after the
# captain answered is still its own question (the N1d cure).
p = d.get("pending")
if isinstance(p, dict) and p.get("what") and not any(
        q.get("mission") == p.get("mission") and q.get("what") == p.get("what")
        for q in qs):
    p = dict(p)
    p.setdefault("id", "pending")
    qs.append(p)
qs.sort(key=lambda q: (q.get("raisedAt") or 0, q.get("id") or ""))
for q in qs:
    print("%s\t%s\t%s" % (q.get("id") or "?", q.get("mission") or "-",
                           flat(q.get("what"))))
PY
}

# A lock around every read-modify-write of autopilot.json. `mkdir` is the
# atomic primitive available in bash 3.2 with no coreutils. The driver's waiter
# and the foreground command both write this file, so without it one of them
# loses its update — and a lost pid is a mode that cannot find its own work.
ap_lock() {
  local tries=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then rm -rf "$LOCKDIR"; continue; fi
    sleep 0.05
  done
}
ap_unlock() { rm -rf "$LOCKDIR"; }

# ap_set <dotted.path> <value>
# The value is parsed as JSON when it parses (so `true`, `3`, `{"a":1}` keep
# their type) and kept as a string otherwise. An EMPTY value DELETES the key —
# that is how a finished drive's pid is cleared, and why `stalled` can tell
# "no driver" from "a driver that is still live".
ap_set() {
  local path="$1" val="${2-}"
  mkdir -p "$LCARS_DIR"
  ap_lock
  "$PY" - "$APJSON" "$path" "$val" <<'PY'
import json, os, sys
f, path, val = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(f))
except FileNotFoundError:
    d = {}
except Exception:
    sys.stderr.write("autopilot: %s exists but is NOT valid JSON - refusing to overwrite it\n" % f)
    sys.exit(2)
parts = path.split(".")
cur = d
for p in parts[:-1]:
    if not isinstance(cur.get(p), dict):
        cur[p] = {}
    cur = cur[p]
leaf = parts[-1]
if val == "":
    cur.pop(leaf, None)
else:
    try:
        cur[leaf] = json.loads(val)
    except Exception:
        cur[leaf] = val
tmp = f + ".tmp.%d" % os.getpid()
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, f)
PY
  local rc=$?
  ap_unlock
  return $rc
}

require_state() {
  [ -f "$APJSON" ] || die "no autopilot.json in $LCARS_DIR — run \`autopilot.sh init --spec <path>\` first."
  # FAIL CLOSED on a record that EXISTS but will not parse. `ap_set` read it as
  # "no file yet" and wrote a fresh empty object over it: one `record` against a
  # mid-JSON truncation reported SUCCESS and took 8 questions, every recorded
  # answer and the whole alignment round with it, with no warning and no backup,
  # while `status` printed an empty shell. An ABSENT file still means "no record
  # yet" (that is how `init` works); an unreadable one stops everything.
  "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$APJSON" 2>/dev/null \
    || die "$APJSON exists but is NOT valid JSON — refusing to read or write it. Repair or restore that file; an empty record would silently replace the whole alignment round."
}

now() { date +%s; }

notify() { # <mission> <gate-type> <summary>
  [ -x "$NOTIFY_BIN" ] || [ -f "$NOTIFY_BIN" ] || return 0
  LCARS_CFG="$CFG" bash "$NOTIFY_BIN" "$1" "$2" "$3" >/dev/null 2>&1 || true
}

# --- mission helpers (read-only over .git/lcars/missions) ------------------
mstate()  { jfile "$MISSIONS/$1/state.json" "$2"; }
mexists() { [ -f "$MISSIONS/$1/state.json" ]; }

# children_of <mission> → the logged bug Missions linked to it.
# The discriminator is the one approve.sh uses: `type` is `bug` AND
# `parentMission` is this Mission. Keeping the two readers in step is what
# stops the mode from releasing (or blocking on) the wrong records.
children_of() {
  local d id
  [ -d "$MISSIONS" ] || return 0
  for d in "$MISSIONS"/*; do
    [ -d "$d" ] || continue
    [ -f "$d/state.json" ] || continue
    [ "$(jfile "$d/state.json" type)" = "bug" ] || continue
    [ "$(jfile "$d/state.json" parentMission)" = "$1" ] || continue
    id="$(basename "$d")"
    printf '%s\n' "$id"
  done
}

open_children_of() {
  local c
  for c in $(children_of "$1"); do
    [ "$(mstate "$c" stage)" = "done" ] && continue
    printf '%s\n' "$c"
  done
}

# driver_live <mission> — the ONE source of truth for "is a drive in flight".
# It is a MEASUREMENT: the recorded owning pid, probed. Not a log grep.
driver_live() {
  local pid; pid="$(ap_j "drivers.$1.pid")"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

slots_in_use() {
  local m n=0
  for m in $(ap_keys drivers); do
    driver_live "$m" && n=$((n + 1))
  done
  printf '%s' "$n"
}

# ==========================================================================
# THE PLAYBOOK TABLE — the contract between this script and AUTOPILOT.md.
# `next` emits one of these actions and cites its heading; the suite asserts
# every heading exists VERBATIM in the installed AUTOPILOT.md. Rename a heading
# and the suite fails; add an action with no prose behind it and it fails too.
# ==========================================================================
PB_align='## 1. The alignment round — one batch of questions, then walk away'
PB_captain_step='## 2. Captain-only steps, collected up front'
PB_foundation='## 3. Foundation — establish the vision, then re-check the test command'
PB_file='## 4. File a milestone through the front door'
PB_drive='## 5. Drive it — backgrounded, with a waiter that watches the process'
PB_verify_gate='## 6. The Verify gate — Number One, then the live check'
PB_land='## 7. Land it — approve, then the hygiene that always follows'
PB_wait='## 8. Waiting, two missions at a time, and the crontab heartbeat'
PB_answer_pending='## 9. The interrupt budget — what actually reaches the captain'
PB_done='## 10. Wrap-up — lead with the time the captain got back'

playbook_heading() {
  case "$1" in
    align)          printf '%s' "$PB_align" ;;
    captain-step)   printf '%s' "$PB_captain_step" ;;
    foundation)     printf '%s' "$PB_foundation" ;;
    file)           printf '%s' "$PB_file" ;;
    drive)          printf '%s' "$PB_drive" ;;
    verify-gate)    printf '%s' "$PB_verify_gate" ;;
    land)           printf '%s' "$PB_land" ;;
    wait)           printf '%s' "$PB_wait" ;;
    answer-pending) printf '%s' "$PB_answer_pending" ;;
    done)           printf '%s' "$PB_done" ;;
  esac
}

cmd_playbook() {
  local a
  for a in align captain-step foundation file drive verify-gate land wait answer-pending done; do
    printf '%s\t%s\n' "$a" "$(playbook_heading "$a")"
  done
}

# ==========================================================================
# init
# ==========================================================================
cmd_init() {
  local spec="" scope="" engine="" deadline="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec)       spec="${2:-}"; shift 2 ;;
      --spec=*)     spec="${1#--spec=}"; shift ;;
      --scope)      scope="${2:-}"; shift 2 ;;
      --scope=*)    scope="${1#--scope=}"; shift ;;
      --engine)     engine="${2:-}"; shift 2 ;;
      --engine=*)   engine="${1#--engine=}"; shift ;;
      --deadline)   deadline="${2:-}"; shift 2 ;;
      --deadline=*) deadline="${1#--deadline=}"; shift ;;
      --force)      force=1; shift ;;
      *)            die "init: unknown argument: $1" ;;
    esac
  done
  [ -n "$spec" ] || die "init: --spec <path|url> is required (the spec is the source of truth for scope)."

  if [ -f "$APJSON" ] && [ "$force" != 1 ]; then
    die "autopilot.json already exists at $APJSON — a run is already configured.
  Pass --force to overwrite it, or edit one key with \`autopilot.sh record <key> <value>\`.
  (Refusing by default because overwriting it would discard the captain's recorded answers.)" 1
  fi

  mkdir -p "$LCARS_DIR" "$APDIR"
  # The captain's test command is RECORDED now, before any approve can promote
  # something else over it. Re-asserting it after approve (see `land`) is only
  # possible because this snapshot exists.
  local tc; tc="$(jfile "$CFG" testCommand)"
  local eng="${engine:-$(jfile "$CFG" engine)}"
  [ -n "$eng" ] || eng="copilot"

  "$PY" - "$APJSON" "$spec" "$scope" "$eng" "$deadline" "$tc" "$(now)" <<'PY'
import json, os, sys
f, spec, scope, engine, deadline, testcmd, started = sys.argv[1:8]
d = {
  "spec": spec,
  "scope": [s for s in (x.strip() for x in scope.split(",")) if s],
  "engine": engine,
  # What the captain lets the mode decide alone. These are the weekend's
  # granted defaults; the alignment round overwrites them with his answers.
  "latitude": {
    "allowed": [
      "re-run a stage",
      "retire and re-file a stuck mission (archive, never delete)",
      "log and resolve product bugs",
      "override a Number One verdict on live evidence, recorded",
      "edit the product's own site and docs"
    ],
    "never": [
      "merge by hand",
      "edit the LCARS source",
      "touch repos outside liveTargets",
      "create tokens or secrets",
      "delete a non-test repo"
    ],
    "stopAndAsk": [
      "an LCARS bug with no verb-level workaround",
      "a scope change",
      "anything outward-facing that was not pre-authorised"
    ]
  },
  "liveTargets": {"host": "", "owners": []},
  # Alignment question 3 ("where it deploys, and what *live* means") had no key
  # to land in, so the tester had to drop the question. It has one now.
  "deploy": {"where": "", "liveMeans": ""},
  "stopRules": {"lcarsBug": "stop-and-report"},
  "report": {"url": ""},
  "deadline": deadline,
  "captainOnlySteps": [],
  "preauthorised": {
    "manualMergeWhenApproveHitsKnownBug": False,
    "liveTestWrites": False
  },
  "testCommand": testcmd,
  "gateTimeout": 600,
  "missions": {},
  "drivers": {},
  # `questions` is the DURABLE record of every question ever raised, answered or
  # not; `pending` is the derived single-question mirror the model-facing surface
  # reads. Writing a question appends to the former and re-derives the latter, so
  # a second question can never delete the first.
  "questions": {},
  "pending": {},
  "startedAt": int(started),
  "lastForecast": ""
}
tmp = f + ".tmp.%d" % os.getpid()
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, f)
PY

  say "wrote $APJSON"
  cat "$APJSON"
  say ""
  say "Next: answer the alignment round, then record the answers with"
  say "  autopilot.sh record liveTargets.host <host>"
  say "  autopilot.sh record captainOnlySteps '[{\"what\":\"…\",\"instructions\":\"…\",\"neededBy\":\"…\",\"done\":false}]'"
  say "then follow $SKILLS_DIR/lcars-buddy/AUTOPILOT.md."
}

# ==========================================================================
# record — the "record, don't infer" primitive the MODEL uses
# ==========================================================================
cmd_record() {
  [ $# -ge 1 ] || die "record: <dotted.key> <value>"
  require_state
  ap_set "$1" "${2-}" || die "record: could not write $1"
  say "recorded $1"
}

# ==========================================================================
# THE PLAN — what `next` and `status` both read from
# ==========================================================================
# Emits "action<TAB>arg<TAB>why", in priority order. This is the ONLY place
# that decides what happens next, so `status` and `next` can never disagree.
build_plan() {
  # OPEN QUESTIONS COME FIRST, AND NO LONGER RETURN. The old body hit
  # answer-pending and returned BEFORE it looked at any mission, so with M0
  # blocked on a question and M1 sitting ready at its Verify gate, `next --all`
  # printed a ONE-ITEM plan: one midnight question parked the entire run, which
  # with the two-slot rule is wrong by design. Now each question is surfaced AND
  # the milestones it blocks — only those — are skipped below.
  local blocked="" qid qmission qwhat
  while IFS="$(printf '\t')" read -r qid qmission qwhat; do
    [ -n "${qid:-}" ] || continue
    printf 'answer-pending\t%s\t%s\n' "${qmission:--}" \
      "a question is waiting for the captain [$qid]: $qwhat"
    if [ -n "${qmission:-}" ] && [ "$qmission" != "-" ]; then
      blocked="$blocked $qmission"
    fi
  done <<EOF
$(open_questions)
EOF

  # A captain-only step that is not done blocks everything that needs it; it is
  # surfaced before any mechanical work so it never lands on the critical path
  # (the weekend found its hub token at 10:40am and SSO at 1pm — both avoidable).
  #
  # A DECLINED step is a recorded OUTCOME, not an absence. The schema used to
  # carry only `done: true|false`, so a step the captain declined ("no deploy
  # token, no Pages tonight") made `next` send him straight back to it; the only
  # escapes were writing `done: true` (a lie in the ledger) or deleting the step
  # (losing that it was ever asked). `declined` is honoured here instead.
  local cs; cs="$("$PY" - "$APJSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for s in d.get("captainOnlySteps") or []:
    if not s.get("done") and not s.get("declined"):
        print(s.get("what", "an unnamed captain-only step"))
        break
PY
)"
  if [ -n "$cs" ]; then
    printf 'captain-step\t-\t%s\n' "$cs"
  fi

  if [ "$(ap_j "foundation.done")" != "true" ] && [ "$(ap_j "foundation.required")" = "true" ]; then
    printf 'foundation\t-\t%s\n' "no test foundation yet — file the initialization mission"
    return 0
  fi

  local used; used="$(slots_in_use)"
  if [ "$used" -ge "$MAX_SLOTS" ]; then
    printf 'wait\t-\t%s\n' "$used/$MAX_SLOTS parallel slots in use — two missions at a time is the ceiling; wait for a waiter to fire"
    return 0
  fi

  local ms id stage verified any=0
  for ms in $(ap_keys scope); do
    id="$(ap_j "missions.$ms.id")"
    if [ -z "$id" ]; then
      printf 'file\t%s\t%s\n' "$ms" "$ms is not filed yet"
      any=1
      continue
    fi
    stage="$(mstate "$id" stage)"
    [ "$stage" = "done" ] && continue
    any=1
    if driver_live "$id"; then
      continue
    fi
    # Blocked on a question of its own: its next step is the captain's answer,
    # already emitted above. It stays OUT of the runnable work but still counts
    # as in-scope, so `done` is never reported over a parked milestone.
    case " $blocked " in
      *" $id "*) continue ;;
    esac
    verified="$(ap_j "missions.$ms.verified")"
    if [ "$stage" = "verify" ]; then
      if [ "$verified" = "true" ]; then
        printf 'land\t%s\t%s\n' "$id" "$ms is verified — approve it and run the hygiene"
      else
        printf 'verify-gate\t%s\t%s\n' "$id" "$ms reached the Verify gate — read Number One, then run the live check"
      fi
      continue
    fi
    printf 'drive\t%s\t%s\n' "$id" "$ms is at $stage with no driver in flight"
  done

  if [ "$any" = 0 ]; then
    printf 'done\t-\t%s\n' "every milestone in scope is done — write the wrap-up"
  fi
}

cmd_next() {
  require_state
  local all=0
  [ "${1:-}" = "--all" ] && all=1
  local plan; plan="$(build_plan)"
  if [ -z "$plan" ]; then
    say "NEXT: wait"
    say "WHY: every milestone in scope has a driver in flight."
    say "PLAYBOOK: $(playbook_heading wait)"
    return 0
  fi
  local action arg why
  IFS="$(printf '\t')" read -r action arg why <<EOF
$(printf '%s\n' "$plan" | head -1)
EOF
  if [ "$arg" = "-" ]; then
    say "NEXT: $action"
  else
    say "NEXT: $action $arg"
  fi
  say "WHY: $why"
  say "PLAYBOOK: $(playbook_heading "$action")"
  # A question for the captain is the top line, but it is HIS step, not the
  # mode's: the work on every other milestone is still runnable and is named
  # here, so one open question cannot park the run.
  if [ "$action" = "answer-pending" ]; then
    local r_action r_arg r_why
    IFS="$(printf '\t')" read -r r_action r_arg r_why <<EOF
$(printf '%s\n' "$plan" | grep -v '^answer-pending' | head -1)
EOF
    if [ -n "${r_action:-}" ]; then
      if [ "$r_arg" = "-" ]; then
        say "ALSO RUNNABLE: $r_action"
      else
        say "ALSO RUNNABLE: $r_action $r_arg"
      fi
      say "  ($r_why — a question on one milestone does not park the others.)"
    fi
  fi
  if [ "$all" = 1 ]; then
    say ""
    say "PLAN (in order):"
    local n=0
    while IFS="$(printf '\t')" read -r action arg why; do
      [ -n "${action:-}" ] || continue
      n=$((n + 1))
      if [ "$arg" = "-" ]; then
        printf '  %s. %s — %s\n' "$n" "$action" "$why"
      else
        printf '  %s. %s %s — %s\n' "$n" "$action" "$arg" "$why"
      fi
    done <<EOF
$(printf '%s\n' "$plan")
EOF
  fi
}

# ==========================================================================
# status — one screen, no log grepping
# ==========================================================================
cmd_status() {
  require_state
  local used; used="$(slots_in_use)"
  say "AUTOPILOT — $CWD"
  say "  spec:     $(ap_j spec)"
  say "  engine:   $(ap_j engine)"
  say "  deadline: $(ap_j deadline)    last forecast: $(ap_j lastForecast)"
  say ""
  say "  scope:"
  local ms id stage drv verified
  for ms in $(ap_keys scope); do
    id="$(ap_j "missions.$ms.id")"
    if [ -z "$id" ]; then
      printf '    %-5s %-26s stage=%-12s gate=%-14s driver=%s\n' "$ms" "(unfiled)" "-" "-" "-"
      continue
    fi
    stage="$(mstate "$id" stage)"
    [ -n "$stage" ] || stage="(no state.json)"
    if driver_live "$id"; then drv="live (pid $(ap_j "drivers.$id.pid"))"; else drv="-"; fi
    verified="$(ap_j "missions.$ms.verified")"
    local gate="-"
    [ "$(mstate "$id" awaitingHuman)" = "true" ] && gate="awaiting-human"
    [ "$stage" = "verify" ] && gate="verify"
    [ "$verified" = "true" ] && gate="$gate (live-verified)"
    printf '    %-5s %-26s stage=%-12s gate=%-14s driver=%s\n' "$ms" "$id" "$stage" "$gate" "$drv"
  done
  say ""
  say "  parallel slots in use: $used/$MAX_SLOTS"
  # EVERY open question, with its id. The old screen said "1" and printed the
  # single `.pending` slot, which is the surface that silently lost one.
  local qs; qs="$(open_questions)"
  local nq; nq="$(printf '%s' "$qs" | grep -c '.' | tr -d ' ')"
  if [ -n "$qs" ] && [ "${nq:-0}" -gt 0 ]; then
    say "  open questions for the captain: $nq"
    local qid qmission qwhat
    while IFS="$(printf '\t')" read -r qid qmission qwhat; do
      [ -n "${qid:-}" ] || continue
      printf '    [%s] %s: %s\n' "$qid" "${qmission:--}" "$qwhat"
    done <<EOF
$qs
EOF
    say "    answer one with: autopilot.sh answered <id> \"<what he said>\""
  else
    say "  open questions for the captain: none"
  fi
  local cs csd
  cs="$("$PY" - "$APJSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
steps = d.get("captainOnlySteps") or []
print(sum(1 for s in steps if not s.get("done") and not s.get("declined")))
PY
)"
  say "  captain-only steps outstanding: ${cs:-0}"
  csd="$("$PY" - "$APJSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for s in d.get("captainOnlySteps") or []:
    if s.get("declined") and not s.get("done"):
        print("    declined: %s%s" % (
            s.get("what") or "an unnamed captain-only step",
            (" — %s" % s["declinedReason"]) if s.get("declinedReason") else ""))
PY
)"
  [ -z "$csd" ] || printf '%s\n' "$csd"
  say ""
  cmd_next
}

# ==========================================================================
# drive — background the real driver, and WAIT ON THE PROCESS
# ==========================================================================
# WHY THE WAITER IS THE DRIVER'S PARENT. A waiter must notice the drive ending
# without a clock and without polling: the weekend's `alarm` wrapper killed an
# `approve` mid-retest and left a reconcile worktree holding the branch. The one
# primitive bash 3.2 has for "block until that process ends, however it ends" is
# `wait` on your OWN child — so the recorded owner process IS the drive's parent
# and simply `wait`s. It cannot overrun, it cannot cut LCARS off, and a SIGKILL
# to the driver returns it immediately.
cmd_drive() {
  local m="${1:?drive: <mission> required}"
  require_state
  mexists "$m" || die "drive: no mission $m in $MISSIONS"
  if driver_live "$m"; then
    die "drive: a driver for $m is already live (pid $(ap_j "drivers.$m.pid")) — one driver per mission." 11
  fi
  # The cap, as a mechanical refusal. The waiter has already written the
  # captain's question; this stops a caller that asks anyway.
  local prior; prior="$(ap_j "drivers.$m.failures")"
  case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
  if [ "$prior" -ge "$MAX_DRIVE_FAILURES" ]; then
    die "drive: $m has already failed $prior drives in a row and the cap is $MAX_DRIVE_FAILURES — the captain has the question (\`autopilot.sh status\`). Clear it with \`autopilot.sh answered <id>\` or \`autopilot.sh record drivers.$m.failures ''\` once the cause is fixed." 11
  fi
  local used; used="$(slots_in_use)"
  if [ "$used" -ge "$MAX_SLOTS" ]; then
    die "drive: $used/$MAX_SLOTS parallel slots already in use — two missions at a time is the ceiling (three drove load to 170 and killed workers)." 11
  fi
  mkdir -p "$APDIR"
  local log="$APDIR/drive-$m.log"
  : >"$log"
  bash "$SELF" _waiter "$m" "$log" >>"$APDIR/waiter-$m.log" 2>&1 </dev/null &
  local wpid=$!
  ap_set "drivers.$m.pid" "$wpid"
  ap_set "drivers.$m.log" "$log"
  ap_set "drivers.$m.startedAt" "$(now)"
  ap_set "drivers.$m.exitedAt" ""
  ap_set "drivers.$m.pickedUpAt" ""
  say "driving $m in the background (owner pid $wpid)"
  say "  log: $log"
  say "  the waiter blocks on the process and records the exit in autopilot.json;"
  say "  ask \`autopilot.sh next\` / \`autopilot.sh stalled\` rather than reading the log."
}

# _waiter <mission> <log> — internal. Starts the real driver as its own child.
cmd_waiter() {
  local m="$1" log="$2"
  local gt; gt="$(ap_j gateTimeout)"
  [ -n "$gt" ] || gt=600
  LCARS_GATE_TIMEOUT="$gt" bash "$RUN_SCRIPT" drive --mission "$m" >>"$log" 2>&1 </dev/null &
  local dpid=$!
  ap_set "drivers.$m.driverPid" "$dpid"
  wait "$dpid"
  local rc=$?
  ap_set "drivers.$m.exitCode" "$rc"

  # THE FAILURE COUNT IS SETTLED BEFORE THE MISSION READS AS EXITED, so anything
  # that sees `exitedAt`/a cleared pid sees a CONSISTENT record rather than a
  # half-written count.
  # THE EXIT CODE IS NOW ACTED ON, AND COUNTED. It used to be written here and
  # only PRINTED by `stalled`, overwritten on every attempt, so `next` happily
  # said `drive <m>` for ever: three failing drives in a row produced three
  # identical next-steps and an unattended run would spin until morning.
  if [ "$rc" -eq 0 ]; then
    ap_set "drivers.$m.failures" ""
  else
    local fails; fails="$(ap_j "drivers.$m.failures")"
    case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
    fails=$((fails + 1))
    ap_set "drivers.$m.failures" "$fails"
    if [ "$fails" -ge "$MAX_DRIVE_FAILURES" ]; then
      write_pending "$m" \
        "$m has failed $fails drives in a row (last exit $rc) and the autopilot has stopped retrying it." \
        "Repeating a failure that never changes is an LCARS bug with no verb-level workaround — one of the four things that may reach you. A fourth attempt would spin until morning and achieve nothing." \
        "LCARS_GATE_TIMEOUT=$gt bash $RUN_SCRIPT drive --mission $m   # in the FOREGROUND; its last log is $log" \
        "nothing was merged and nothing to undo. Once the cause is fixed, \`autopilot.sh answered <id>\` clears the counter and the mode resumes."
    fi
  fi
  ap_set "drivers.$m.driverPid" ""
  ap_set "drivers.$m.exitedAt" "$(now)"
  ap_set "drivers.$m.pid" ""
  # NO PING FOR A ROUTINE STOP. `notify … drive-stopped` used to fire on EVERY
  # drive exit, exit 0 included — three pings from three routine stage stops in
  # one tester run. AUTOPILOT.md § 9 promises exactly four things reach the
  # captain; a stage stop the mode handles itself is not one of them, so the only
  # notification left on this path is the one write_pending sends when the
  # failure cap turns into a question.
}

# ==========================================================================
# stalled — what the crontab heartbeat calls
# ==========================================================================
# IT DECIDES FROM RECORDED PIDS, NOT FROM LOG TEXT. A pid probed with `kill -0`
# is a measurement; a driver log is prose that a human also writes into, and a
# marker-grep heuristic over it has mis-read a live pipeline as finished before.
# It always exits 0: a heartbeat that fails is a heartbeat the captain deletes.
cmd_stalled() {
  require_state
  local m pid exited picked stage n=0
  for m in $(ap_keys drivers); do
    if driver_live "$m"; then continue; fi
    exited="$(ap_j "drivers.$m.exitedAt")"
    [ -n "$exited" ] || continue
    picked="$(ap_j "drivers.$m.pickedUpAt")"
    if [ -n "$picked" ] && [ "$picked" -ge "$exited" ] 2>/dev/null; then continue; fi
    stage="$(mstate "$m" stage)"
    [ "$stage" = "done" ] && continue
    n=$((n + 1))
    printf 'STALLED: %s (stage=%s, exit=%s) — its driver ended and nobody picked it up.\n' \
      "$m" "${stage:-unknown}" "$(ap_j "drivers.$m.exitCode")"
  done
  if [ "$n" -gt 0 ]; then
    printf '%s stalled mission(s). Run `autopilot.sh next` for the step, then `autopilot.sh record drivers.<id>.pickedUpAt %s`.\n' \
      "$n" "$(now)"
  fi
  return 0
}

# ==========================================================================
# land — approve, then the hygiene that always follows
# ==========================================================================
# THE PRE-STAGED QUESTION. A merge LCARS refuses is NOT retried, worked around,
# or finished by hand — it is written to autopilot.json.pending as four fields
# (what is blocked, why, the ONE command that would run, the rollback) and the
# milestone stops with exit 10. The captain's "OK" then costs seconds, and the
# permission classifier never sees a second route to a blocked outcome.
# IT APPENDS. The old body began `ap_set "pending" "{}"`, which DESTROYED the
# previous question before writing the new one. It now writes a new key in
# `questions` and re-derives the `.pending` mirror; nothing already recorded is
# touched. One locked read-modify-write, so a waiter and a foreground command
# cannot lose each other's question.
# AND IT IS IDEMPOTENT. Appending made re-raising the SAME problem append a
# duplicate every time — and because this is the script's ONE `notify` call
# site, every duplicate pushed the captain again. A question already OPEN on
# the same (mission, what) pair is now a no-op here, so EVERY caller inherits
# it (the drive-failure cap as much as `land`) and the ping fires only when a
# question is genuinely appended.
write_pending() { # <mission> <what> <why> <command> <rollback>
  local qid
  ap_lock
  qid="$("$PY" - "$APJSON" "$1" "$2" "$3" "$4" "$5" "$(now)" <<'PY'
import json, os, sys
f, mission, what, why, cmd, rollback, ts = sys.argv[1:8]
try:
    d = json.load(open(f))
except Exception:
    d = {}
qs = d.get("questions")
if not isinstance(qs, dict):
    qs = {}
# Carry a hand-written `.pending` into the ledger before adding to it, so the
# a question the model recorded by hand is never the one this write loses.
# (No apostrophes in here: bash scans for the closing paren of $( ) WITHOUT
# knowing about the heredoc, so a stray quote inside it breaks the parse.)
# THE KEY HERE IS THE SAME ONE THE RAISE PATH BELOW USES: the pair
# (mission, what), gated on not answeredAt. It used to match on `what` ALONE,
# across ANSWERED questions too, so a hand-written question that RECURRED after
# the captain answered it was dropped on the floor - absent from status, no
# notification, no questions entry - and the same text on a DIFFERENT mission
# went the same way. A question nobody will ever see is the worst outcome this
# ledger has. A pending with no mission key reads as mission None on both
# sides, so it dedupes against its own adopted copy and is still adopted once.
p = d.get("pending")
carried = False
if isinstance(p, dict) and p.get("what") and not any(
        isinstance(q, dict) and not q.get("answeredAt")
        and q.get("mission") == p.get("mission")
        and q.get("what") == p.get("what") for q in qs.values()):
    n = 1
    while ("q%d" % n) in qs:
        n += 1
    p = dict(p)
    p["id"] = "q%d" % n
    qs[p["id"]] = p
    carried = True
# IDEMPOTENT. Raising a question that is ALREADY OPEN on the same
# (mission, what) pair is the SAME problem, so it is a NO-OP: no new key, no
# notification, and the open question keeps its ORIGINAL raisedAt. Without
# this, re-running `land` on a mission still blocked by the same bug child
# appended q3, q4, q5 byte-identical and pushed the captain three times for
# one problem - the interrupt-budget violation AUTOPILOT.md section 9
# forbids. The pair is the key, NOT the mission: a drive-failure-cap question
# and a land question on one mission are two DIFFERENT problems and must stay
# two questions. An ANSWERED question never suppresses a new one - a problem
# that recurs after it was answered is a real new event.
dup = None
for k in sorted(qs):
    q = qs[k]
    if (isinstance(q, dict) and not q.get("answeredAt")
            and q.get("mission") == mission and q.get("what") == what):
        dup = q
        break
if dup is not None:
    if carried:
        d["questions"] = qs
        openq = [q for q in qs.values() if isinstance(q, dict) and not q.get("answeredAt")]
        openq.sort(key=lambda q: (q.get("raisedAt") or 0, q.get("id") or ""))
        d["pending"] = dict(openq[0]) if openq else {}
        tmp = f + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as fh:
            json.dump(d, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, f)
    sys.stdout.write("=" + (dup.get("id") or "?"))
    sys.exit(0)
n = 1
while ("q%d" % n) in qs:
    n += 1
qid = "q%d" % n
qs[qid] = {"id": qid, "mission": mission, "what": what, "why": why,
           "command": cmd, "rollback": rollback, "raisedAt": int(ts)}
d["questions"] = qs
openq = [q for q in qs.values() if isinstance(q, dict) and not q.get("answeredAt")]
openq.sort(key=lambda q: (q.get("raisedAt") or 0, q.get("id") or ""))
d["pending"] = dict(openq[0]) if openq else {}
tmp = f + ".tmp.%d" % os.getpid()
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, f)
sys.stdout.write(qid)
PY
)"
  ap_unlock
  # The dedupe reported an already-open question: say so and stop. The ONE
  # notify call site in this script is below, so a duplicate cannot ping.
  case "$qid" in
    "="*)
      say ""
      say "ALREADY OPEN [${qid#=}] — same mission, same question. Not re-raised, not re-notified."
      say "  what:     $2"
      say "  record his answer with: autopilot.sh answered ${qid#=} \"<what he said>\""
      return 0
      ;;
  esac
  [ -n "$qid" ] || qid="?"
  notify "$1" "awaiting-human" "$2"
  say ""
  say "QUESTION FOR THE CAPTAIN [$qid] (recorded in $APJSON .questions, mirrored in .pending):"
  say "  what:     $2"
  say "  why:      $3"
  say "  command:  $4"
  say "  rollback: $5"
  say "  record his answer with: autopilot.sh answered $qid \"<what he said>\""
}

# ==========================================================================
# answered — the counterpart of write_pending, and the ONLY way a question is
# closed. It never deletes: the question stays on the record with the answer
# beside it, and the `.pending` mirror moves on to the next open one. A capped
# mission's failure counter is cleared, because the captain answering IS the
# thing that unblocks it.
# ==========================================================================
cmd_answered() {
  [ $# -ge 1 ] || die "answered: <question-id|mission> [\"<his answer>\"] — \`status\` prints the ids."
  require_state
  local out rc
  ap_lock
  out="$("$PY" - "$APJSON" "$1" "${2-}" "$(now)" 2>&1 <<'PY'
import json, os, sys
f, want, answer, ts = sys.argv[1:5]
try:
    d = json.load(open(f))
except Exception:
    sys.stderr.write("no readable autopilot.json")
    sys.exit(1)
qs = d.get("questions")
if not isinstance(qs, dict):
    qs = {}
hit = None
if want in qs and isinstance(qs[want], dict) and not qs[want].get("answeredAt"):
    hit = qs[want]
if hit is None:
    for k in sorted(qs):
        q = qs[k]
        if isinstance(q, dict) and not q.get("answeredAt") and q.get("mission") == want:
            hit = q
            break
if hit is None:
    # A hand-written `.pending` with no ledger entry: carry it in, then answer
    # it. The fact that it was asked survives either way.
    p = d.get("pending")
    if isinstance(p, dict) and p.get("what") and want in ("pending", p.get("id"), p.get("mission")):
        n = 1
        while ("q%d" % n) in qs:
            n += 1
        hit = dict(p)
        hit["id"] = "q%d" % n
        qs[hit["id"]] = hit
if hit is None:
    sys.stderr.write("no OPEN question with id or mission '%s' — `autopilot.sh status` lists them" % want)
    sys.exit(1)
hit["answeredAt"] = int(ts)
if answer:
    hit["answer"] = answer
d["questions"] = qs
openq = [q for q in qs.values() if isinstance(q, dict) and not q.get("answeredAt")]
openq.sort(key=lambda q: (q.get("raisedAt") or 0, q.get("id") or ""))
d["pending"] = dict(openq[0]) if openq else {}
tmp = f + ".tmp.%d" % os.getpid()
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, f)
nxt = d["pending"].get("id") if d["pending"] else None
print("recorded the answer to %s (%s). %s" % (
    hit.get("id"), hit.get("mission") or "no mission",
    ("Still open: %s — %s" % (nxt, d["pending"].get("what"))) if nxt
    else "No questions are open for the captain now."))
print(hit.get("mission") or "")
PY
)"; rc=$?
  ap_unlock
  [ "$rc" -eq 0 ] || die "answered: ${out:-could not record the answer}"
  local m; m="$(printf '%s' "$out" | sed -n '2p')"
  [ -z "$m" ] || ap_set "drivers.$m.failures" ""
  say "$(printf '%s' "$out" | sed -n '1p')"
}

# Stale reconcile worktrees. Every blocked reconcile left a reconcile.XXXXXX
# worktree holding the mission branch with a half-done merge in it, which then
# blocked the NEXT attempt. `reset --hard` clears the in-progress state and the
# worktree is removed; the mode never completes that merge itself.
clean_stale_reconciles() {
  local wt
  for wt in $("$GIT_BIN" -C "$CWD" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'); do
    case "$(basename "$wt")" in
      reconcile.*) ;;
      *) continue ;;
    esac
    say "  hygiene: removing the stale reconcile worktree $wt"
    "$GIT_BIN" -C "$wt" reset --hard >/dev/null 2>&1 || true
    "$GIT_BIN" -C "$CWD" worktree remove --force "$wt" >/dev/null 2>&1 || true
    rm -rf "$wt"
  done
  "$GIT_BIN" -C "$CWD" worktree prune >/dev/null 2>&1 || true
}

cmd_land() {
  local m="${1:?land: <mission> required}"
  require_state
  mexists "$m" || die "land: no mission $m in $MISSIONS"

  # Pre-check 1: nothing is landed while its own driver is still in flight.
  if driver_live "$m"; then
    die "land: a driver for $m is still live (pid $(ap_j "drivers.$m.pid")) — let the waiter fire first." 11
  fi

  # Pre-check 2: open logged children. S232 made approve refuse these; the mode
  # checks FIRST so the refusal arrives as a question rather than a stack trace,
  # and so no half-approve has to be cleaned up.
  local open; open="$(open_children_of "$m" | tr '\n' ' ')"
  open="${open% }"
  if [ -n "$open" ]; then
    write_pending "$m" \
      "$m cannot be landed: its logged bug Mission(s) $open are still open." \
      "Approving a parent with bugs in flight ships a known-broken merge — LCARS refuses it, and so does the mode." \
      "bash $SKILLS_DIR/lcars-resolve-logs/resolve-logs.sh --parent $m   # then re-verify, then: autopilot.sh land $m" \
      "nothing to undo — no approve was attempted."
    exit 10
  fi

  # The captain's test command, as recorded BEFORE any approve could promote
  # something else over it.
  local want_tc; want_tc="$(ap_j testCommand)"

  say "landing $m — calling the real approve verb (the mode never merges itself)"
  local out rc
  out="$(bash "$APPROVE_SCRIPT" --mission "$m" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'

  if [ "$rc" -ne 0 ]; then
    # A refused merge. Clean up whatever the blocked reconcile left, then ask.
    clean_stale_reconciles
    local reason; reason="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g')"
    write_pending "$m" \
      "LCARS refused to merge $m (approve exit $rc): $reason" \
      "Merging it by hand is on the never-list, so this stops here with the evidence ready rather than finding a second route." \
      "bash $APPROVE_SCRIPT --mission $m   # re-run once the refusal's cause is cleared" \
      "nothing was merged; the stale reconcile worktree (if any) has been removed, so a retry starts clean."
    exit 10
  fi

  # APPROVE EXIT 0 IS NOT PROOF OF A MERGE. approve has an exit-0-did-NOT-merge
  # outcome: its self-heal reconcile (approve.sh reconcileStatus
  # awaiting-reapprove) reconciles main into the branch, re-tests it green, and
  # then WAITS for the captain -- "Reapprove to merge. Mission stays at verify
  # awaiting your reapprove" -- and exits 0. Gating on the exit code alone
  # printed `landed <m>`, ran the whole post-merge hygiene and wrote a
  # {"what":"merged"} ledger line while main had not moved: silent, unbounded
  # (a land that reports success is invisible to the drive-failure cap), and it
  # FALSIFIES the record of what shipped. The mission's OWN state.json is the
  # evidence, so read it back: landed only when the stage is really `done`.
  # The mode never passes --reapprove itself. That sign-off is the captain's by
  # design, so this is a real stop-and-ask and the question carries his command.
  local st; st="$(mstate "$m" stage)"
  if [ "$st" != "done" ]; then
    write_pending "$m" \
      "approve exited 0 but did NOT merge $m — it is still at stage '${st:-unknown}', not done." \
      "LCARS reconciled main into the branch and re-tested it green, then stopped for your reapprove; reapprove is YOUR sign-off, so the mode will not give it and will not claim a merge that did not happen." \
      "bash $APPROVE_SCRIPT --mission $m --reapprove   # then: autopilot.sh land $m" \
      "nothing was merged and no post-merge hygiene ran, so there is nothing to undo."
    exit 10
  fi

  say "  approve succeeded and $m is at stage done. Hygiene:"

  # H1. Re-assert the captain's test command. approve has promoted an
  # uninstalled runner over a recorded stdlib command before; the captain's
  # value wins, always.
  local have_tc; have_tc="$(jfile "$CFG" testCommand)"
  if [ -n "$want_tc" ] && [ "$have_tc" != "$want_tc" ]; then
    say "  hygiene: testCommand changed during approve ('$have_tc') — re-asserting the captain's '$want_tc'"
    "$PY" - "$CFG" "$want_tc" <<'PY'
import json, os, sys
f, tc = sys.argv[1], sys.argv[2]
d = json.load(open(f))
d["testCommand"] = tc
tmp = f + ".tmp.%d" % os.getpid()
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, f)
PY
  else
    say "  hygiene: testCommand unchanged ('$have_tc') — nothing to re-assert"
  fi

  # H2. Release every folded child. LCARS does not release them on fold
  # (feedback #19), so 13 Done cards once read "Number One has the conn".
  local c
  for c in $(children_of "$m"); do
    say "  hygiene: releasing folded child $c (xo off)"
    bash "$XO_SCRIPT" off "$c" >/dev/null 2>&1 || say "    (xo off $c reported a problem — ledgered, not retried by another route)"
  done

  # H3. Stale reconcile worktrees.
  clean_stale_reconciles

  # H4. Pull main, so the next milestone starts from the merge.
  if "$GIT_BIN" -C "$CWD" pull --ff-only >/dev/null 2>&1; then
    say "  hygiene: pull --ff-only on $("$GIT_BIN" -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null) — up to date"
  else
    say "  hygiene: pull --ff-only did not fast-forward — left alone (not forced)"
  fi

  # H5. Record it. The ledger, not the transcript, is the record.
  ledger_append decisions "{\"what\":\"merged\",\"mission\":\"$m\",\"via\":\"approve.sh\"}"
  ap_set "drivers.$m.pickedUpAt" "$(now)"
  say "landed $m."
}

# ==========================================================================
# push-gated — the gate the orchestrator must never hand-roll
# ==========================================================================
# THE BUG THIS EXISTS FOR. A hand-rolled "suite then push" matched the word
# `FAILED` as success and pushed a red `main` for seven minutes. The fix is to
# gate on the EXIT CODE and nothing else; the output scan below is a second,
# narrower refusal (never a reason to push), because a suite that prints FAILED
# and still exits 0 is itself a reason to stop and look.
cmd_push_gated() {
  require_state
  local tc; tc="$(ap_j testCommand)"
  [ -n "$tc" ] || tc="$(jfile "$CFG" testCommand)"
  [ -n "$tc" ] || die "push-gated: no testCommand recorded in autopilot.json or $CFG — refusing to push ungated."
  say "push-gated: running the recorded suite: $tc"
  local out rc
  out="$( cd "$CWD" && eval "$tc" 2>&1 )"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ "$rc" -ne 0 ]; then
    say "push-gated: the suite FAILED (exit $rc) — NOTHING pushed."
    return 1
  fi
  if printf '%s\n' "$out" | grep -qE '(^|[^A-Za-z])(FAILED|FAIL:)([^A-Za-z]|$)'; then
    say "push-gated: the suite exited 0 but its output reports FAILED — refusing to push, and this disagreement is itself worth a look."
    return 1
  fi
  say "push-gated: suite exit 0 — pushing."
  if "$GIT_BIN" -C "$CWD" push; then
    say "push-gated: pushed."
    return 0
  fi
  say "push-gated: the suite was green but the push itself failed — nothing retried by another route."
  return 1
}

# ==========================================================================
# worktree — detached, with a throwaway HOME
# ==========================================================================
# ALWAYS DETACHED. Holding a mission branch checked out blocked LCARS from
# landing a green fix for an hour. And exploring a CLI needs a throwaway HOME:
# a `draft --help` once created a junk draft on the real machine.
cmd_worktree() {
  local m="${1:?worktree: <mission> required}"
  require_state
  mexists "$m" || die "worktree: no mission $m in $MISSIONS"
  local br; br="$(mstate "$m" branch)"
  [ -n "$br" ] || die "worktree: mission $m has no branch in its state.json"
  local base="${TMPDIR:-/tmp}"
  local wt home
  wt="$(mktemp -d "$base/lcars-ap-wt-XXXXXX")"   || die "worktree: could not make a worktree dir"
  home="$(mktemp -d "$base/lcars-ap-home-XXXXXX")" || die "worktree: could not make a throwaway HOME"
  if ! "$GIT_BIN" -C "$CWD" worktree add --detach "$wt" "$br" >/dev/null 2>&1; then
    rm -rf "$wt"
    rm -rf "$home"
    die "worktree: git worktree add --detach failed for $br"
  fi
  mkdir -p "$home/.config"
  say "WORKTREE: $wt"
  say "HOME: $home"
  say "  detached at $("$GIT_BIN" -C "$wt" rev-parse --short HEAD) ($br)"
  say "  run live checks as:  HOME=$home sh -c 'cd $wt && …'"
  say "  tear it down with:   $GIT_BIN -C $CWD worktree remove --force $wt"
}

# ==========================================================================
# ledger — the durable records
# ==========================================================================
ledger_append() { # <kind> <json>
  local kind="$1" json="$2" file
  case "$kind" in
    feedback)  file="$LCARS_DIR/lcars-feedback.jsonl" ;;
    overrides) file="$LCARS_DIR/autopilot-overrides.jsonl" ;;
    decisions) file="$LCARS_DIR/decisions.jsonl" ;;
    *) die "ledger: unknown kind '$kind' — use feedback | overrides | decisions." ;;
  esac
  mkdir -p "$LCARS_DIR"
  "$PY" - "$file" "$json" "$(now)" <<'PY'
import json, sys
f, body, ts = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.loads(body)
except Exception as e:
    sys.stderr.write("lcars autopilot: ledger: not valid JSON (%s)\n" % e)
    sys.exit(1)
if not isinstance(d, dict):
    sys.stderr.write("lcars autopilot: ledger: the entry must be a JSON object\n")
    sys.exit(1)
d.setdefault("ts", int(ts))
with open(f, "a") as fh:
    fh.write(json.dumps(d, sort_keys=True) + "\n")
PY
}

cmd_ledger() {
  [ $# -ge 2 ] || die "ledger: <feedback|overrides|decisions> '<json>'"
  ledger_append "$1" "$2" || die "ledger: refused the entry"
  say "appended to the $1 ledger"
}

# ==========================================================================
# heartbeat — ONE crontab line
# ==========================================================================
# WHY crontab AND NOT A HARNESS TOOL. The weekend's heartbeat was a Claude Code
# cron tool, and the design notes still say so. LCARS ships to people who are
# not inside Claude Code — a harness-only tool cannot be the autopilot's
# heartbeat, because on their machine it does not exist. `crontab` is on every
# POSIX box, it survives the session dying, and the captain can read and delete
# the line himself. The mode owns exactly ONE line, tagged so `remove` can find
# it without touching anything else in his crontab.
HB_MARK="# LCARS-AUTOPILOT"
hb_line() {
  printf '17 * * * * cd %s && bash %s stalled >> %s/heartbeat.log 2>&1 %s %s\n' \
    "$CWD" "$SELF" "$APDIR" "$HB_MARK" "$CWD"
}
hb_current() { "$CRONTAB_BIN" -l 2>/dev/null; }
# READ THE WHOLE TABLE INTO MEMORY FIRST, then write. Piping a reader straight
# into `crontab -` means the writer can truncate the table while the reader is
# still walking it — which is exactly how a first draft of this ate the
# captain's unrelated cron entries. His crontab is not ours to lose.
hb_without_ours() {
  local cur; cur="$(hb_current)"
  [ -n "$cur" ] || return 0
  printf '%s\n' "$cur" | grep -vF -- "$HB_MARK $CWD" || true
}

cmd_heartbeat() {
  local sub="${1:-status}"
  case "$sub" in
    install)
      require_state
      mkdir -p "$APDIR"
      local keep; keep="$(hb_without_ours)"
      { [ -n "$keep" ] && printf '%s\n' "$keep"; hb_line; } | "$CRONTAB_BIN" - \
        || die "heartbeat: crontab refused the new table"
      say "heartbeat installed (one crontab line, minute 17):"
      hb_line | sed 's/^/  /'
      say "  it calls \`autopilot.sh stalled\` and acts only when a pipeline ended with nobody picking it up."
      ;;
    remove)
      # WRITING AN EMPTY TABLE IS A SUCCESS. `{ [ -n "$rest" ] && printf …; }`
      # made the empty case exit 1 — `[ -n "" ]` is false — and under
      # `set -o pipefail` that reddened the whole pipeline, so `remove` DIED
      # claiming "crontab refused the new table" on a removal that had in fact
      # worked, while `status` then correctly reported not installed. The
      # captain's crontab is empty, so it fired on his machine every time. An
      # `if` with no `else` yields 0 when the condition is false. The post-check
      # below is unchanged: it still refuses to CLAIM a removal that did not
      # happen.
      local rest; rest="$(hb_without_ours)"
      { if [ -n "$rest" ]; then printf '%s\n' "$rest"; fi; } | "$CRONTAB_BIN" - \
        || die "heartbeat: crontab refused the new table"
      if hb_current | grep -qF -- "$HB_MARK $CWD"; then
        die "heartbeat: the line is still present after remove — refusing to claim it is gone."
      fi
      say "heartbeat removed (the captain's other crontab entries are untouched)."
      ;;
    status)
      if hb_current | grep -qF -- "$HB_MARK $CWD"; then
        say "heartbeat: installed"
        hb_current | grep -F -- "$HB_MARK $CWD" | sed 's/^/  /'
      else
        say "heartbeat: not installed for $CWD"
      fi
      ;;
    *) die "heartbeat: install | remove | status" ;;
  esac
}

# ==========================================================================
# dispatch
# ==========================================================================
SUB="${1:-}"
[ $# -gt 0 ] && shift
case "$SUB" in
  init)        cmd_init "$@" ;;
  status)      cmd_status "$@" ;;
  next)        cmd_next "$@" ;;
  playbook)    cmd_playbook "$@" ;;
  record)      cmd_record "$@" ;;
  answered)    cmd_answered "$@" ;;
  drive)       cmd_drive "$@" ;;
  _waiter)     cmd_waiter "$@" ;;
  stalled)     cmd_stalled "$@" ;;
  land)        cmd_land "$@" ;;
  push-gated)  cmd_push_gated "$@" ;;
  worktree)    cmd_worktree "$@" ;;
  ledger)      cmd_ledger "$@" ;;
  heartbeat)   cmd_heartbeat "$@" ;;
  ''|-h|--help|help) usage ;;
  *)           printf 'lcars autopilot: unknown subcommand %s\n' "$SUB" >&2; usage ;;
esac
