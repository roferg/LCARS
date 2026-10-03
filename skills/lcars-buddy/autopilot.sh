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
#   autopilot.sh worktree <mission> | worktree --branch <branch>
#   autopilot.sh live-check <mission> --type cli|web|workflow[,…]
#   autopilot.sh live-check done <mission> --verdict pass|bugs
#   autopilot.sh workflow-run <mission> <workflow.yml> [--evidence-dir <dir>]
#   autopilot.sh file-bug --parent <mission> --prd <bug-prd.md>
#   autopilot.sh policy --verdict high|medium|low [--reason product|infrastructure]
#                       --live-check pass|bugs [--mission <m>] [--evidence <path>]
#   autopilot.sh report [--out <path>]
#   autopilot.sh ledger feedback|overrides|decisions '<json>'
#   autopilot.sh heartbeat install|remove|status
#   autopilot.sh record <dotted.key> <value>
#   autopilot.sh answered <question-id|mission> ["<his answer>"]
#   autopilot.sh ask "<what>" --mission <m> [--why …] [--command …] [--rollback …]
#   autopilot.sh playbook
#
# EXIT CODES that mean something:
#   0   done
#   10  a question for the CAPTAIN was recorded in autopilot.json.questions and the
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
LOG_SCRIPT="${LCARS_LOG_SCRIPT:-$SKILLS_DIR/lcars-log/log.sh}"
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
  ask "<what>" --mission <m> [--why <w>] [--command <c>] [--rollback <r>]
                       raise a question YOURSELF (a product call, a scope change, a
                       standing-rule conflict). It lands in .questions with a real id and
                       pings him once. NEVER hand-edit .pending — it is a derived mirror.

  drive <mission>      run.sh drive --mission, backgrounded, waiter on the PROCESS
  stalled              what the crontab heartbeat calls; decides from recorded pids
  land <mission>       approve.sh --mission + hygiene; exit 10 = a question was written
  push-gated           run the recorded testCommand, push ONLY on exit 0
  worktree <mission> | worktree --branch <br>
                       git worktree add --detach + a throwaway HOME; prints both.
                       --branch needs no autopilot record (Number One passes it)
  live-check <mission> --type cli|web|workflow[,…]
                       the detached worktree + throwaway HOME + the evidence dir, and the
                       CHECKLIST(S) to follow. The MODEL does the looking.
  live-check done <mission> --verdict pass|bugs
                       record the outcome (there is no default — an unrecorded live
                       check would read later as one that passed)
  workflow-run <mission> <workflow.yml>
                       run the job's steps EXACTLY as CI does — same cwd, same command,
                       the env Actions sets — and name the first failing step
  file-bug --parent <m> --prd <f>
                       validate the evidence-first template (AC #1 = `Observed live:`),
                       then file it through `lcars log`. Refuses a filing it cannot see.
  policy --verdict <v> [--reason product|infrastructure] --live-check <pass|bugs>
                       print the ONE action from the merge table; `--table` prints the
                       whole table; an override is recorded WITH its evidence path
  report [--out <p>]   render the progress page from the ledgers (nothing from a clock)
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

EXIT CODES: 0 ok | 10 a question for the captain was recorded in .questions | 11 pre-check
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
# IT READS THE LEDGER AND NOTHING ELSE (S233). This function used to ALSO
# synthesise a row out of `.pending` when the model had written a question there
# by hand, which is what made that field storage in some code paths and a mirror
# in others — see `ap_adopt_pending` for the five defects that ambiguity cost.
# An orphan `.pending` is now ADOPTED into `questions` before any command can
# read it, so there is nothing left here to cope with: every row has a real id
# that `answered <id>` closes.
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

# ==========================================================================
# ap_adopt_pending — the ONE place a hand-written `.pending` becomes a real
# question, and it runs the MOMENT the record is read
# ==========================================================================
# ONE HOME, ENFORCED BY CONSTRUCTION. `.pending` used to be BOTH a derived
# mirror (on the raise path) and the SOLE STORAGE for a question the model wrote
# by hand — the old AUTOPILOT.md § 9 instructed exactly that — with nothing
# declaring which. That single ambiguity produced FIVE separate defects over
# five rounds of testing, each one a different function disagreeing about it:
#   1. a second question deleted the first (the mirror was overwritten);
#   2. duplicates piled up, each one pinging the captain;
#   3. a recurrence was swallowed because the raise and adoption paths used two
#      different dedupe keys;
#   4. a hand-written question was MASKED whenever any other was open;
#   5. answering ANY question DESTROYED an un-adopted hand-written one: the
#      mirror was re-derived over it, `questions` never held it, and the mode
#      told the captain "No questions are open for the captain now" and carried
#      on without him.
# Every one of those was a reader coping with the orphan slightly differently,
# so a sixth careful reader was never the cure. A question is now RAISED with a
# verb — `autopilot.sh ask`, or `write_pending` from inside the driver — and
# lands in `questions` with a real id; `.pending` is ONLY ever the derived
# mirror of the oldest open question. There is no code path left that reads a
# question OUT of `.pending`.
#
# OLDER RUNS STILL PRODUCE ORPHANS, so the field is still HONOURED — but as a
# one-way repair at the moment it is seen (`require_state`, i.e. before any
# command looks at the record, and again at the top of `write_pending` for the
# waiter, which has no `require_state`). Adoption is not deferred until
# something else happens to be raised; that laziness was defect 4 and 5's
# shared cause.
#
# IDEMPOTENT, AND IT NEVER RESURRECTS. The dedupe is the (mission, what) pair
# over the OPEN set — byte-for-byte the key the raise path uses — so the mirror
# of an open question matches its own ledger entry and adoption is a no-op,
# while a problem that RECURS after the captain answered earns a genuinely new
# question. Once a question is answered the mirror moves off it, so there is
# nothing left on disk to re-adopt.
#
# IT DOES NOT NOTIFY. `write_pending` holds this script's ONE `notify` call
# site. Adoption is a storage repair, not a new event; a ping here would re-push
# a question the captain has already been shown, which § 9's interrupt budget
# forbids.
ap_adopt_pending() {
  [ -f "$APJSON" ] || return 0
  ap_lock
  "$PY" - "$APJSON" "$(now)" <<'PY'
import json, os, sys
f, ts = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(f))
except Exception:
    # A corrupt record is NOT repaired here. `require_state` fails closed on it
    # and names the file; silently rewriting it is what cost a whole alignment
    # round once already.
    sys.exit(0)
p = d.get("pending")
if not (isinstance(p, dict) and p.get("what")):
    sys.exit(0)
qs = d.get("questions")
if not isinstance(qs, dict):
    qs = {}
if any(isinstance(q, dict) and not q.get("answeredAt")
       and q.get("mission") == p.get("mission")
       and q.get("what") == p.get("what") for q in qs.values()):
    sys.exit(0)
n = 1
while ("q%d" % n) in qs:
    n += 1
q = dict(p)
q["id"] = "q%d" % n
q["handWritten"] = True
if not q.get("raisedAt"):
    q["raisedAt"] = int(ts)
qs[q["id"]] = q
d["questions"] = qs
openq = [x for x in qs.values() if isinstance(x, dict) and not x.get("answeredAt")]
openq.sort(key=lambda x: (x.get("raisedAt") or 0, x.get("id") or ""))
d["pending"] = dict(openq[0]) if openq else {}
tmp = f + ".tmp.%d" % os.getpid()
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, f)
PY
  ap_unlock
  return 0
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
  # ADOPT ON FIRST SIGHT. An orphan `.pending` left by an older run (or by the
  # pre-S233 playbook) becomes a real ledger question HERE — before any command
  # reads the record — which is precisely why nothing downstream has to cope
  # with one. Deliberately AFTER the corrupt-state refusal above: a record this
  # function would not read is a record adoption must not rewrite.
  ap_adopt_pending
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
# or finished by hand — it is recorded in autopilot.json.questions as four fields
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
  # ADOPT FIRST, THEN RAISE (S233). The carry used to live INSIDE the python
  # below, which made this the second function with an opinion about what
  # `.pending` is. It is now one call to the one adopter — and it is called here
  # as well as in `require_state` because `_waiter` reaches this function
  # without going through `require_state` at all.
  ap_adopt_pending
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
# NO ADOPTION IN HERE ANY MORE (S233). `ap_adopt_pending`, called above, is the
# only function that carries a hand-written `.pending` into the ledger. This
# body now does exactly one thing: raise a question, or recognise that the same
# one is already open. `.pending` below is WRITTEN, never read as storage.
# (No apostrophes in here: bash scans for the closing paren of $( ) WITHOUT
# knowing about the heredoc, so a stray quote inside it breaks the parse.)
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
    # NOTHING TO WRITE on a duplicate. The old body had to flush here because it
    # might have carried a hand-written pending in the same pass; adoption is a
    # separate, already-committed step now, so a no-op raise touches no bytes.
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
# ask — the ONE supported way for the MODEL to raise a question by hand
# ==========================================================================
# WHY A VERB AND NOT A FIELD. AUTOPILOT.md § 9 used to tell the model to write
# its own question — a product call, a scope change, a standing-rule conflict
# including a permission denial — straight into `autopilot.json.pending`. That
# instruction is what made `.pending` load-bearing STORAGE on one path while it
# stayed a derived MIRROR on another, and that one ambiguity cost five defects
# (listed on `ap_adopt_pending`). `ask` gives the hand-raised question the SAME
# home as every other: it lands in `questions` immediately, with a real id, and
# `.pending` goes back to being only a mirror.
#
# IT ADDS NO LOGIC. It parses flags and calls `write_pending`, so it inherits
# that function's (mission, what) dedupe over the OPEN set, its single `notify`
# call site, and its printed `answered <id>` line verbatim — the same behaviour
# `land`'s own refusal gets. A duplicate ask is a no-op and does NOT ping again;
# the same question recurring AFTER he answered is a real new event and does.
#
# IT EXITS 0. `land`'s exit 10 means "this merge stopped"; a question is not a
# milestone stop. § 9: one open question blocks ITS milestone and no other, so
# `ask` returns and the mode keeps working — `next` names the runnable rest.
cmd_ask() {
  local what="" mission="" why="" cmdline="" rollback=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mission)    mission="${2:-}"; shift 2 ;;
      --mission=*)  mission="${1#--mission=}"; shift ;;
      --why)        why="${2:-}"; shift 2 ;;
      --why=*)      why="${1#--why=}"; shift ;;
      --command)    cmdline="${2:-}"; shift 2 ;;
      --command=*)  cmdline="${1#--command=}"; shift ;;
      --rollback)   rollback="${2:-}"; shift 2 ;;
      --rollback=*) rollback="${1#--rollback=}"; shift ;;
      -*)           die "ask: unknown argument: $1" ;;
      *)            [ -z "$what" ] || die "ask: one question per call — quote the whole question as a single argument."
                    what="$1"; shift ;;
    esac
  done
  [ -n "$what" ] || die "ask: the question is required.
  autopilot.sh ask \"<what you need from him>\" --mission <id> [--why <why it is safe/needed>] [--command <the ONE command that would run>] [--rollback <how to undo it>]"
  # A QUESTION MUST NAME ITS MILESTONE, because `next` blocks only the milestone
  # a question is filed against (§ 9). An unattributed question would either
  # park nothing or park everything; `--mission -` says "no milestone" on
  # purpose and is the only way to get that.
  [ -n "$mission" ] || die "ask: --mission <id> is required so the question blocks only ITS milestone (use \`--mission -\` for a question that belongs to no milestone)."
  require_state
  [ -n "$why" ] || why="-"
  [ -n "$cmdline" ] || cmdline="-"
  [ -n "$rollback" ] || rollback="nothing to undo — nothing was attempted."
  write_pending "$mission" "$what" "$why" "$cmdline" "$rollback"
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
# `pending` NAMES A QUESTION, it does not hold one (S233). The mirror is
# re-derived on every write, so `answered pending` is a POINTER to the oldest
# open question - the one the model-facing single-question surface shows. It
# reads only the mirror id field: the question itself is always
# already in the ledger, because an orphan was adopted before this ran.
if want == "pending":
    p = d.get("pending")
    if isinstance(p, dict) and p.get("id"):
        want = p["id"]
if want in qs and isinstance(qs[want], dict) and not qs[want].get("answeredAt"):
    hit = qs[want]
by_mission = False
if hit is None:
    for k in sorted(qs):
        q = qs[k]
        if isinstance(q, dict) and not q.get("answeredAt") and q.get("mission") == want:
            hit = q
            by_mission = True
            break
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
# ANSWERING BY MISSION IS AMBIGUOUS WHEN TWO QUESTIONS SHARE ONE, so say so
# rather than resolving it silently. It closes the OLDEST open question on that
# mission - the long-standing behaviour - and names what is still open on it, by
# id, so a second answer is one obvious command away. It may never close two,
# and it may never drop one on the floor.
same = [q for q in openq if hit.get("mission") and q.get("mission") == hit.get("mission")]
if by_mission and same:
    print("  NOTE: %s still has %d open question(s) — %s. Answering by MISSION closes the OLDEST one only; answer the rest by id." % (
        hit.get("mission"), len(same), ", ".join(q.get("id") or "?" for q in same)))
PY
)"; rc=$?
  ap_unlock
  [ "$rc" -eq 0 ] || die "answered: ${out:-could not record the answer}"
  local m; m="$(printf '%s' "$out" | sed -n '2p')"
  [ -z "$m" ] || ap_set "drivers.$m.failures" ""
  say "$(printf '%s' "$out" | sed -n '1p')"
  # Line 2 is the mission (read above); anything after it is a note for the
  # captain and is printed as-is.
  printf '%s\n' "$out" | sed -n '3,$p'
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
  # `worktree <mission>` resolves the branch from the autopilot record;
  # `worktree --branch <br>` is handed it (S239 — see wt_prepare). With an
  # explicit branch there is nothing to look up, so neither autopilot.json nor
  # a mission is required: the branch IS the record for this call.
  local m="" br=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch)   br="${2:-}"; shift 2 ;;
      --branch=*) br="${1#--branch=}"; shift ;;
      *)          m="$1"; shift ;;
    esac
  done
  if [ -z "$br" ]; then
    [ -n "$m" ] || die "worktree: <mission>, or --branch <branch>"
    require_state
    mexists "$m" || die "worktree: no mission $m in $MISSIONS"
    br="$(mstate "$m" branch)"
  fi
  local pair wt home
  pair="$(wt_prepare "${m:-$br}" "$br")" || exit 1
  wt="$(printf '%s' "$pair" | cut -f1)"
  home="$(printf '%s' "$pair" | cut -f2)"
  wt_say "$wt" "$home" "$br"
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
# S234 — LIVE VERIFICATION: the part that found every bug
# ==========================================================================
# Over 26–29 Sep 2026 Number One filed 0 of 31 bugs. All 31 came from a model
# running the real thing by hand. Its 16 misses were every one a REACH error —
# no screen, nothing seeded, a stub that made the seam untestable — never a
# judgement error. So the split below is deliberate and permanent:
#
#   THE MODEL DOES THE LOOKING.  THE SCRIPT OWNS THE SETUP, THE EVIDENCE PATHS
#   AND THE RECORD.
#
# `live-check` prepares a DETACHED worktree and a THROWAWAY HOME (checking from
# the checked-out branch, or with the captain's own HOME, is how a whole round
# got verified against the wrong tree and how an unconfigurable product looked
# configured), makes the evidence dir under the mission's own state, prints the
# checklist(s) for the product type, and records the verdict. It judges nothing.
#
# THE CHECKLISTS LIVE IN lcars-run/, NOT HERE, because the rebuilt Number One
# reads the same files. One source, two readers: the buddy follows the prose,
# the fenced worker lifts each item's `run:`/`workflow:`/`read:` template.
LIVE_CHECK_DIR="${LCARS_LIVE_CHECK_DIR:-$SKILLS_DIR/lcars-run/live-check}"
LIVE_CHECK_TYPES="cli web workflow"

# label_for <mission-id> → the milestone label in scope that names it, or "".
label_for() {
  local ms
  for ms in $(ap_keys scope); do
    if [ "$(ap_j "missions.$ms.id")" = "$1" ]; then printf '%s' "$ms"; return 0; fi
  done
  return 1
}

# wt_prepare <mission> → "<worktree>\t<home>". Dies (in its own subshell) on
# any failure, so EVERY caller must test the result.
wt_prepare() {
  local m="$1" br="${2:-}"
  # S239: THE BRANCH MAY BE NAMED OUTRIGHT. Number One's harness (xo-run.py)
  # reuses THIS helper — one machinery, because a second "detach a worktree" is
  # a second thing that can be subtly wrong and the buddy and the first officer
  # must check the same tree. It holds the branch already (from the mission's
  # own state.json, read by xo.sh) and has no autopilot.json, so it passes the
  # branch rather than asking this script to look the mission up.
  [ -n "$br" ] || br="$(mstate "$m" branch)"
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
  printf '%s\t%s\n' "$wt" "$home"
}

# wt_say <worktree> <home> <branch> — the four lines both callers print.
wt_say() {
  say "WORKTREE: $1"
  say "HOME: $2"
  say "  detached at $("$GIT_BIN" -C "$1" rev-parse --short HEAD) ($3)"
  say "  run live checks as:  HOME=$2 sh -c 'cd $1 && …'"
  say "  tear it down with:   $GIT_BIN -C $CWD worktree remove --force $1"
}

cmd_live_check() {
  if [ "${1:-}" = "done" ]; then shift; cmd_live_check_done "$@"; return $?; fi
  local m="${1:-}"
  [ -n "$m" ] || die "live-check: <mission> --type cli|web|workflow[,…]   (or: live-check done <mission> --verdict pass|bugs)"
  shift
  local types=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --type)   types="${2:-}"; shift 2 ;;
      --type=*) types="${1#--type=}"; shift ;;
      *)        die "live-check: unknown argument '$1'" ;;
    esac
  done
  require_state
  mexists "$m" || die "live-check: no mission $m in $MISSIONS"
  [ -n "$types" ] || die "live-check: --type is required — one or more of: $LIVE_CHECK_TYPES (comma-separated). Pick every type the milestone touches."
  # VALIDATE EVERY TYPE BEFORE PREPARING ANYTHING. A half-prepared check with
  # one checklist printed is worse than a refusal: somebody follows the half.
  local t k known
  for t in $(printf '%s' "$types" | tr ',' ' '); do
    known=0
    for k in $LIVE_CHECK_TYPES; do [ "$t" = "$k" ] && known=1; done
    [ "$known" = 1 ] || die "live-check: '$t' is not a product type I have a checklist for — I know: $LIVE_CHECK_TYPES. Nothing was prepared and no checklist was printed."
    [ -f "$LIVE_CHECK_DIR/$t.md" ] || die "live-check: no checklist at $LIVE_CHECK_DIR/$t.md — is LCARS installed?"
  done

  local evdir="$MISSIONS/$m/live-check"
  mkdir -p "$evdir"
  local pair wt home br
  pair="$(wt_prepare "$m")" || exit 1
  wt="$(printf '%s' "$pair" | cut -f1)"
  home="$(printf '%s' "$pair" | cut -f2)"
  br="$(mstate "$m" branch)"

  local tlist; tlist="$(printf '%s' "$types" | tr ',' ' ')"
  say "LIVE CHECK — $m"
  say "  types:    $tlist"
  wt_say "$wt" "$home" "$br"
  say "EVIDENCE: $evdir"
  say "  write each item's evidence to the NN-* name ITS OWN item gives (NN is the item number)."
  say "  a screenshot is LOOKED AT, not merely produced."
  say ""

  # RECORD, DON'T INFER: what was prepared is written now, so `done` does not
  # have to guess which types were checked or where the evidence went.
  ap_set "liveChecks.$m.types"    "$("$PY" -c 'import json,sys; print(json.dumps(sys.argv[1].split()))' "$tlist")"
  ap_set "liveChecks.$m.evidence" "$evdir"
  ap_set "liveChecks.$m.worktree" "$wt"
  ap_set "liveChecks.$m.home"     "$home"

  for t in $tlist; do
    say "===== CHECKLIST: $t ($LIVE_CHECK_DIR/$t.md) ====="
    cat "$LIVE_CHECK_DIR/$t.md"
    say ""
  done
  say "WHEN DONE:  $SELF live-check done $m --verdict pass|bugs"
  say "A BUG:      $SELF file-bug --parent $m --prd <bug-prd.md>   (template: $SKILLS_DIR/lcars-buddy/bug-prd.md)"
}

cmd_live_check_done() {
  local m="${1:-}"
  [ -n "$m" ] || die "live-check done: <mission> --verdict pass|bugs"
  shift
  local verdict="" note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)   verdict="${2:-}"; shift 2 ;;
      --verdict=*) verdict="${1#--verdict=}"; shift ;;
      --note)      note="${2:-}"; shift 2 ;;
      --note=*)    note="${1#--note=}"; shift ;;
      *)           die "live-check done: unknown argument '$1'" ;;
    esac
  done
  require_state
  mexists "$m" || die "live-check done: no mission $m in $MISSIONS"
  case "$verdict" in
    pass|bugs) ;;
    "") die "live-check done: --verdict is required (pass | bugs). There is no default: an unrecorded live check would read later as one that passed." ;;
    *)  die "live-check done: '$verdict' is not a verdict — use pass or bugs." ;;
  esac
  local evdir; evdir="$(ap_j "liveChecks.$m.evidence")"
  [ -n "$evdir" ] || evdir="$MISSIONS/$m/live-check"
  ap_set "liveChecks.$m.verdict" "$verdict"
  ap_set "liveChecks.$m.at"      "$(now)"
  ap_set "liveChecks.$m.evidence" "$evdir"
  [ -n "$note" ] && ap_set "liveChecks.$m.note" "$note"
  local label; label="$(label_for "$m" || true)"
  [ -n "$label" ] && ap_set "missions.$label.liveCheck" "$verdict"
  ledger_append decisions "$("$PY" - "$m" "$verdict" "$evdir" "$note" <<'PY'
import json, sys
print(json.dumps({"kind": "live-check", "mission": sys.argv[1],
                  "verdict": sys.argv[2], "evidence": sys.argv[3],
                  "note": sys.argv[4]}))
PY
)" || die "live-check done: the ledger refused the entry"
  say "live check for $m recorded: $verdict"
  say "  evidence: $evdir"
  [ -n "$label" ] && say "  milestone $label updated"
  if [ "$verdict" = bugs ]; then
    say "  NEXT: file each one with \`$SELF file-bug --parent $m --prd <bug-prd.md>\`, then resolve-logs."
  else
    say "  NEXT: \`$SELF policy --mission $m --live-check pass\` for the merge call."
  fi
  return 0
}

# ==========================================================================
# workflow-run — the REAL ENTRYPOINT check
# ==========================================================================
# On the modelled weekend three of six live breaks were visible ONLY to the real
# runner, and one of them was a package module invoked as a FILE:
# `python3 pkg/render.py` dies with "attempted relative import with no known
# parent package" while `python3 -m pkg.render` works — and every test that
# imports the function, or runs it as a module, passes.
#
# So this runs the job's steps the way CI runs them: the step's OWN command,
# from the step's OWN cwd (`working-directory`), with the env Actions always
# sets. It is a MINIMAL step runner on purpose — no `act`, no third-party
# dependency to be wrong, and no "helpful" rewriting of a command into the form
# that works. A runner that passes the module-as-a-file step is broken.
cmd_workflow_run() {
  local m="${1:-}" wf="${2:-}"
  [ -n "$m" ] && [ -n "$wf" ] || die "workflow-run: <mission> <workflow.yml> [--job <name>] [--repository <owner/name>] [--server-url <url>] [--event <json>] [--root <dir>] [--evidence <name>]"
  shift 2
  local job="" repository="" server="" event="" root="" evname="02-workflow-run.txt"
  local evdirarg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --job)          job="${2:-}"; shift 2 ;;
      --job=*)        job="${1#--job=}"; shift ;;
      --repository)   repository="${2:-}"; shift 2 ;;
      --repository=*) repository="${1#--repository=}"; shift ;;
      --server-url)   server="${2:-}"; shift 2 ;;
      --server-url=*) server="${1#--server-url=}"; shift ;;
      --event)        event="${2:-}"; shift 2 ;;
      --event=*)      event="${1#--event=}"; shift ;;
      --root)         root="${2:-}"; shift 2 ;;
      --root=*)       root="${1#--root=}"; shift ;;
      --evidence)     evname="${2:-}"; shift 2 ;;
      --evidence=*)   evname="${1#--evidence=}"; shift ;;
      --evidence-dir)   evdirarg="${2:-}"; shift 2 ;;
      --evidence-dir=*) evdirarg="${1#--evidence-dir=}"; shift ;;
      *)              die "workflow-run: unknown argument '$1'" ;;
    esac
  done
  # S239: Number One's harness runs this very runner for a `workflow` step and
  # writes its transcript BESIDE THE BROWSER SHOTS, under xo/shots/<look>/, so
  # the First Officer's report serves it with no new surface anywhere. With the
  # evidence directory named there is nothing to look up in the autopilot record
  # — so a mission (and autopilot.json) is not required for that call.
  if [ -z "$evdirarg" ]; then
    require_state
    mexists "$m" || die "workflow-run: no mission $m in $MISSIONS"
  fi
  [ -f "$wf" ] || die "workflow-run: no workflow file at $wf"
  wf="$(cd "$(dirname "$wf")" && pwd)/$(basename "$wf")"
  # The repo root is the one the workflow's own paths are relative to — the
  # directory holding .github/, not whatever cwd the buddy happens to be in.
  if [ -z "$root" ]; then
    case "$wf" in
      */.github/workflows/*) root="${wf%/.github/workflows/*}" ;;
      *)                     root="$CWD" ;;
    esac
  fi
  [ -d "$root" ] || die "workflow-run: no such root directory: $root"
  if [ -z "$repository" ]; then
    local url; url="$("$GIT_BIN" -C "$CWD" remote get-url origin 2>/dev/null || true)"
    repository="$("$PY" - "${url:-}" <<'PY'
import re, sys
u = sys.argv[1].rstrip("/")
u = re.sub(r'\.git$', '', u)
parts = [p for p in re.split(r'[:/]', u) if p]
print("/".join(parts[-2:]) if len(parts) >= 2 else "owner/repo")
PY
)"
  fi
  [ -n "$server" ] || server="https://github.com"
  local evdir="${evdirarg:-$MISSIONS/$m/live-check}"
  mkdir -p "$evdir"
  local out="$evdir/$evname"
  local rc
  wf_run_py "$wf" "$root" "$repository" "$server" "$job" "$event" "$evdir" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  say ""
  say "EVIDENCE: $out"
  return "$rc"
}

# The step runner itself. Kept as one python program because a YAML subset
# reader in bash 3.2 would be the least trustworthy part of this script.
wf_run_py() {
  "$PY" - "$@" <<'PY'
import json, os, re, subprocess, sys

wf_path, root, repository, server, job_sel, event_path, evdir = sys.argv[1:8]

# ---- a MINIMAL YAML reader -------------------------------------------------
# Deliberately not PyYAML (not a harness dependency) and deliberately not a
# general parser: it reads the workflow subset — nested maps, sequences,
# scalars and `|`/`>` block scalars — and nothing else.
def strip_comment(line):
    out = []
    q = None
    for ch in line:
        if q:
            out.append(ch)
            if ch == q:
                q = None
            continue
        if ch in "\"'":
            q = ch; out.append(ch); continue
        if ch == "#":
            if out and out[-1] not in (" ", "\t"):
                out.append(ch); continue
            break
        out.append(ch)
    return "".join(out).rstrip()

def scalar(s):
    s = s.strip()
    if not s:
        return ""
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    if s == "true":  return True
    if s == "false": return False
    if s in ("null", "~"): return None
    if re.match(r'^-?\d+$', s):
        return int(s)
    return s

def indent_of(line):
    return len(line) - len(line.lstrip(" "))

def block(lines, i, ind):
    items = None
    mapping = None
    while i < len(lines):
        raw = lines[i]
        if not raw.strip():
            i += 1; continue
        cur = indent_of(raw)
        if cur < ind:
            break
        if cur > ind:
            i += 1; continue
        body = raw.strip()
        if body.startswith("- ") or body == "-":
            if mapping is not None:
                break
            if items is None:
                items = []
            rest = body[2:] if body.startswith("- ") else ""
            sub = cur + 2
            if re.match(r'^[A-Za-z_][\w.\-]*\s*:', rest):
                elem = [" " * sub + rest]
                j = i + 1
                while j < len(lines):
                    r2 = lines[j]
                    if not r2.strip():
                        elem.append(r2); j += 1; continue
                    if indent_of(r2) < sub:
                        break
                    elem.append(r2); j += 1
                val, _ = block(elem, 0, sub)
                items.append(val); i = j
            else:
                items.append(scalar(rest)); i += 1
            continue
        m = re.match(r'^([^:]+):\s*(.*)$', body)
        if not m:
            i += 1; continue
        if items is not None:
            break
        if mapping is None:
            mapping = {}
        key = scalar(m.group(1))
        val = m.group(2)
        if val in ("|", "|-", "|+", ">", ">-", ">+"):
            j = i + 1
            buf = []
            bind = None
            while j < len(lines):
                r2 = lines[j]
                if not r2.strip():
                    buf.append(""); j += 1; continue
                if indent_of(r2) <= cur:
                    break
                if bind is None:
                    bind = indent_of(r2)
                buf.append(r2[bind:]); j += 1
            while buf and not buf[-1].strip():
                buf.pop()
            if val.startswith(">"):
                text = " ".join(x.strip() for x in buf if x.strip())
            else:
                text = "\n".join(buf)
            if not val.endswith("-"):
                text += "\n"
            mapping[key] = text
            i = j
        elif not val.strip():
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines) and indent_of(lines[j]) > cur:
                sub_val, i2 = block(lines, j, indent_of(lines[j]))
                mapping[key] = sub_val; i = i2
            elif j < len(lines) and indent_of(lines[j]) == cur and lines[j].strip().startswith("- "):
                sub_val, i2 = block(lines, j, cur)
                mapping[key] = sub_val; i = i2
            else:
                mapping[key] = None; i = j
        else:
            mapping[key] = scalar(val); i += 1
    if items is not None:
        return items, i
    return (mapping if mapping is not None else {}), i

lines = [strip_comment(l) for l in open(wf_path).read().splitlines()]
doc, _ = block(lines, 0, 0)
if not isinstance(doc, dict):
    print("workflow-run: %s does not parse as a workflow" % wf_path)
    sys.exit(2)
jobs = doc.get("jobs") or {}
if not isinstance(jobs, dict) or not jobs:
    print("workflow-run: no jobs in %s" % wf_path)
    sys.exit(2)
job_name = job_sel or list(jobs.keys())[0]
if job_name not in jobs:
    print("workflow-run: no job %r in %s (jobs: %s)" % (job_name, wf_path, ", ".join(jobs)))
    sys.exit(2)
job = jobs[job_name] or {}
steps = job.get("steps") or []
if not isinstance(steps, list):
    steps = []

owner = repository.split("/")[0]
name = repository.split("/")[-1]

# The env Actions ALWAYS sets. GITHUB_EVENT_PATH must point at a file that
# really exists: a step that reads it is the one that breaks on the runner.
if not event_path:
    event_path = os.path.join(evdir, "workflow-run-event.json")
    with open(event_path, "w") as fh:
        json.dump({"repository": {"full_name": repository, "name": name,
                                  "owner": {"login": owner}},
                   "sender": {"login": owner}}, fh, indent=2)
        fh.write("\n")

base = dict(os.environ)
base.update({
    "CI": "true",
    "GITHUB_ACTIONS": "true",
    "GITHUB_SERVER_URL": server,
    "GITHUB_REPOSITORY": repository,
    "GITHUB_REPOSITORY_OWNER": owner,
    "GITHUB_EVENT_PATH": event_path,
    "GITHUB_WORKSPACE": root,
})
def as_env(d):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out[str(k)] = "" if v is None else (str(v).lower() if isinstance(v, bool) else str(v))
    return out
base.update(as_env(doc.get("env")))
base.update(as_env(job.get("env")))

def default_wd(d):
    try:
        return (d.get("defaults") or {}).get("run", {}).get("working-directory")
    except Exception:
        return None
job_wd = default_wd(job) or default_wd(doc) or "."

print("WORKFLOW-RUN — %s" % wf_path)
print("  job:        %s" % job_name)
print("  root:       %s" % root)
print("  repository: %s    server: %s" % (repository, server))
print("  event:      %s" % event_path)
print("  steps run exactly as CI runs them: the step's own command, the step's own cwd.")
print("")

ran = 0
skipped = 0
failed = None
for n, step in enumerate(steps, start=1):
    if not isinstance(step, dict):
        continue
    run = step.get("run")
    uses = step.get("uses")
    label = step.get("name") or uses or (str(run).strip().splitlines() or ["(unnamed)"])[0]
    print("STEP %d: %s" % (n, label))
    if uses and not run:
        skipped += 1
        print("  SKIP: `uses: %s` is a packaged action — workflow-run executes `run:` steps only." % uses)
        print("        It is UNPROVEN, not passed. Prove it by reading what it published (workflow.md item 6).")
        print("")
        continue
    if not run:
        skipped += 1
        print("  SKIP: the step has no `run:` command.")
        print("")
        continue
    shell = step.get("shell") or "bash"
    if shell not in ("bash", "sh"):
        skipped += 1
        print("  SKIP: shell `%s` — this runner executes bash/sh steps only. UNPROVEN, not passed." % shell)
        print("")
        continue
    wd = step.get("working-directory") or job_wd
    cwd = os.path.normpath(os.path.join(root, str(wd)))
    env = dict(base)
    env.update(as_env(step.get("env")))
    print("  cwd: %s" % cwd)
    for cl in str(run).rstrip("\n").splitlines():
        print("  run: %s" % cl)
    if not os.path.isdir(cwd):
        failed = label
        print("  EXIT: 1")
        print("  the step's `working-directory` does not exist in a clean checkout: %s" % cwd)
        print("")
        break
    argv = [shell, "--noprofile", "--norc", "-eo", "pipefail", "-c", str(run)] \
        if shell == "bash" else [shell, "-e", "-c", str(run)]
    proc = subprocess.Popen(argv, cwd=cwd, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = proc.communicate()[0]
    try:
        out = out.decode("utf-8", "replace")
    except Exception:
        out = str(out)
    for ol in out.rstrip("\n").splitlines():
        print("    %s" % ol)
    ran += 1
    print("  EXIT: %d" % proc.returncode)
    print("")
    if proc.returncode != 0:
        failed = label
        break

if failed is not None:
    print("FIRST FAILING STEP: %s" % failed)
    print("  That is the command CI runs, from the cwd CI runs it in. Do NOT rewrite it")
    print("  into a form that works — fix the step, or fix what it calls.")
    sys.exit(12)

print("ALL STEPS PASSED (%d run, %d skipped)" % (ran, skipped))
PY
}

# ==========================================================================
# file-bug — evidence first, or it is not filed
# ==========================================================================
# THE PRD STYLE THAT GOT FIXES THROUGH FIRST TIME — distilled from the weekend
# archive (evidence/filed-prds/), which is where the style came from and NOT an
# exemplar to copy: those PRDs predate this template and this validator refuses
# them. The one exemplar is bug-prd.md's own worked example. The style: the
# title states the broken behaviour as a sentence; the Goal states the
# corrected invariant; AC #1 is literally `Observed live: …` with the exact
# output and the real identifiers; and where the bug sits at a producer/consumer
# seam there is a ROUND-TRIP criterion that uses both real halves with no
# hand-written fixture between them. A PRD that describes the bug in prose
# instead got re-filed.
#
# This verb VALIDATES the template and then calls `lcars log` — it re-implements
# nothing about filing, linking or labelling. And it does not report a filing it
# cannot see: a `log.sh` that exits 0 without linking a child is a refusal here,
# because "approve exited 0" was once reported as a merge.
cmd_file_bug() {
  local parent=""
  local n=0
  local -a PRDS=()
  local -a EXTRA=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --parent)   parent="${2:-}"; shift 2 ;;
      --parent=*) parent="${1#--parent=}"; shift ;;
      --prd)      PRDS[$n]="${2:-}"; n=$((n + 1)); shift 2 ;;
      --prd=*)    PRDS[$n]="${1#--prd=}"; n=$((n + 1)); shift ;;
      --attach|--attach=*|--model-override|--model-override=*)
        case "$1" in
          --attach|--model-override) EXTRA[${#EXTRA[@]}]="$1"; EXTRA[${#EXTRA[@]}]="${2:-}"; shift 2 ;;
          *)                         EXTRA[${#EXTRA[@]}]="$1"; shift ;;
        esac
        ;;
      *) die "file-bug: unknown argument '$1'" ;;
    esac
  done
  require_state
  [ -n "$parent" ] || die "file-bug: --parent <mission> is required — a logged bug is always a CHILD of the mission it was found in, and grounding needs the parent's code."
  [ "$n" -gt 0 ] || die "file-bug: --prd <file> is required (once per bug). The template is $SKILLS_DIR/lcars-buddy/bug-prd.md."
  mexists "$parent" || die "file-bug: no parent mission $parent in $MISSIONS"
  [ -x "$LOG_SCRIPT" ] || [ -f "$LOG_SCRIPT" ] || die "file-bug: no lcars log at $LOG_SCRIPT"

  # VALIDATE EVERY PRD FIRST, so a bad second PRD does not leave a filed first.
  local i p msg
  i=0
  while [ "$i" -lt "$n" ]; do
    p="${PRDS[$i]}"
    [ -f "$p" ] || die "file-bug: no PRD at $p"
    if ! msg="$(bug_prd_problems "$p")"; then
      printf 'lcars autopilot: file-bug: %s is not an evidence-first bug PRD.\n' "$p" >&2
      printf '%s\n' "$msg" >&2
      printf 'Nothing was filed. The template is %s/lcars-buddy/bug-prd.md.\n' "$SKILLS_DIR" >&2
      exit 1
    fi
    i=$((i + 1))
  done

  local before="$APDIR/file-bug.before.$$" after="$APDIR/file-bug.after.$$"
  mkdir -p "$APDIR"
  children_of "$parent" | sort >"$before"

  local -a ARGS=()
  ARGS[${#ARGS[@]}]="--parent"; ARGS[${#ARGS[@]}]="$parent"
  i=0
  while [ "$i" -lt "$n" ]; do
    ARGS[${#ARGS[@]}]="--prd"; ARGS[${#ARGS[@]}]="${PRDS[$i]}"
    i=$((i + 1))
  done
  if [ "${#EXTRA[@]}" -gt 0 ]; then
    for p in "${EXTRA[@]}"; do ARGS[${#ARGS[@]}]="$p"; done
  fi
  local lrc=0
  bash "$LOG_SCRIPT" "${ARGS[@]}" || lrc=$?
  children_of "$parent" | sort >"$after"
  local new; new="$(comm -13 "$before" "$after")"
  rm -f "$before" "$after"
  if [ "$lrc" -ne 0 ]; then
    die "file-bug: \`lcars log\` exited $lrc — nothing is claimed as filed. Read its message above."
  fi
  if [ -z "$new" ]; then
    die "file-bug: \`lcars log\` exited 0 but no linked bug Mission appeared under $parent — refusing to report a filing I cannot see. Check $MISSIONS and the log output above."
  fi
  local c
  for c in $new; do
    if [ "$(mstate "$c" parentMission)" != "$parent" ]; then
      die "file-bug: the new Mission $c is not linked to $parent (parentMission is '$(mstate "$c" parentMission)') — refusing to report it as filed."
    fi
    say "FILED: $c  (parent $parent — linked; \`lcars log\` labels its issue lcars:linked)"
    ledger_append decisions "$("$PY" - "$parent" "$c" <<'PY'
import json, sys
print(json.dumps({"kind": "bug-filed", "parent": sys.argv[1], "bug": sys.argv[2]}))
PY
)" >/dev/null || true
  done
  say ""
  say "NEXT: resolve every logged bug in one batch, then re-run the live check with DIFFERENT data:"
  say "  bash $SKILLS_DIR/lcars-resolve-logs/resolve-logs.sh --parent $parent"
  say "  $SELF live-check $parent --type <types>      # different data this round"
  return 0
}

# bug_prd_problems <prd> — prints the problems and returns 1, or returns 0.
# A PRE-FLIGHT, not a second authority: `lcars file` is still the gate that
# counts. Running it here means the model is told what is missing BEFORE a
# filing starts, which is the difference between an edit and a re-file.
bug_prd_problems() {
  "$PY" - "$1" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
probs = []

def section(label):
    # BOTH shapes lcars file accepts: the bold inline label and the heading.
    return re.search(r'(?:^|\n)[ \t]*(?:\*\*%s[^*\n]*:\*\*|#{1,6}[ \t]*%s\b)'
                     % (re.escape(label), re.escape(label)), t, re.I)

for label in ("Mission", "Type", "Goal", "Acceptance Criteria",
              "Out of Scope", "Constraints"):
    if not section(label):
        probs.append("missing the '%s' section — `lcars file` requires it and would "
                     "refuse the filing later." % label)

ty = re.search(r'(?:^|\n)[ \t]*\*\*Type:?\*\*[ \t]*:?[ \t]*([^\n]+)', t, re.I)
if ty and ty.group(1).strip().strip("`").lower() != "bug":
    probs.append("Type is '%s' — a logged bug's Type is `bug`." % ty.group(1).strip())

seam = re.search(r'(?:^|\n)[ \t]*\*\*Seam:?\*\*[ \t]*:?[ \t]*([^\n]+)', t, re.I)
if not seam:
    probs.append("no '**Seam:**' line. Declare the producer -> consumer pair this bug "
                 "sits at, or `none`. Six of the modelled weekend's live breaks sat at "
                 "a seam their tests stubbed, so this is not optional.")

# AC #1 — the first bullet under Acceptance Criteria.
acs = []
m = re.search(r'(?:^|\n)[ \t]*(?:\*\*Acceptance Criteria:?\*\*|#{1,6}[ \t]*Acceptance Criteria\b)[^\n]*\n(.*?)(?=\n[ \t]*(?:\*\*[A-Z][^*\n]*:\*\*|#{1,6}[ \t]*[A-Z])|\Z)',
              t, re.I | re.S)
if m:
    for line in m.group(1).splitlines():
        s = line.strip()
        if s.startswith(("- ", "* ", "+ ")) or re.match(r'^\d+\.\s', s):
            acs.append(re.sub(r'^(?:[-*+]\s+|\d+\.\s+)', '', s))
if not acs:
    probs.append("the Acceptance Criteria section has no criteria in it.")
else:
    first = re.sub(r'^\*\*|^\*', '', acs[0]).strip()
    if not re.match(r'observed live\s*:', first, re.I):
        probs.append("AC #1 is not an `Observed live:` line. It reads %r. The FIRST "
                     "criterion must be `Observed live: <the exact output you saw>` "
                     "with the real identifiers (the command, the ids, the paths, the "
                     "hosts) — that is the single thing that got fixes through first "
                     "time, because the worker can reproduce it." % first[:70])
    if seam and seam.group(1).strip().strip("`.").lower() not in ("none", "n/a", "na", "-"):
        if not any(re.search(r'round[ -]?trip', a, re.I) for a in acs):
            probs.append("a Seam is declared (%s) but no criterion asks for a ROUND-TRIP "
                         "test. Require one that drives BOTH REAL HALVES with no "
                         "hand-written fixture between them — a test that stubs the seam "
                         "it claims to prove is not proof."
                         % seam.group(1).strip()[:60])

for p in probs:
    print("  - %s" % p)
sys.exit(1 if probs else 0)
PY
}

# ==========================================================================
# policy — ONE action from the two verdicts, and an override that is recorded
# ==========================================================================
# Playbook § 4, as a function instead of as prose, because applying it by hand
# is how a milestone got merged on a verdict nobody wrote down:
#
#   live check BUGS          -> send-back          (whatever Number One said)
#   pass + high              -> merge
#   pass + medium            -> merge+follow-ups
#   pass + low  (product)    -> send-back
#   pass + low  (infra only) -> override           (recorded, WITH the evidence)
#
# Number One scored every CLI or integration milestone `low` for reasons it
# could not reach, so the live check decided every merge. THE MERGE IS STILL THE
# BUDDY'S CALL: this prints the recommendation and the commands; the buddy
# decides, and every override is written down.
POLICY_ACTIONS='merge merge+follow-ups send-back override'

cmd_policy() {
  local verdict="" reason="" live="" mission="" evidence="" note="" table=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)      verdict="${2:-}"; shift 2 ;;
      --verdict=*)    verdict="${1#--verdict=}"; shift ;;
      --reason)       reason="${2:-}"; shift 2 ;;
      --reason=*)     reason="${1#--reason=}"; shift ;;
      --live-check)   live="${2:-}"; shift 2 ;;
      --live-check=*) live="${1#--live-check=}"; shift ;;
      --mission)      mission="${2:-}"; shift 2 ;;
      --mission=*)    mission="${1#--mission=}"; shift ;;
      --evidence)     evidence="${2:-}"; shift 2 ;;
      --evidence=*)   evidence="${1#--evidence=}"; shift ;;
      --note)         note="${2:-}"; shift 2 ;;
      --note=*)       note="${1#--note=}"; shift ;;
      --table)        table=1; shift ;;
      *)              die "policy: unknown argument '$1'" ;;
    esac
  done
  if [ "$table" = 1 ]; then policy_table; return 0; fi
  require_state
  # The verdict can come from Number One's own file rather than a flag, so
  # nobody has to retype what the verifier already wrote.
  if [ -z "$verdict" ] && [ -n "$mission" ]; then
    verdict="$(jfile "$MISSIONS/$mission/xo/verdict.json" score)"
  fi
  [ -n "$verdict" ] || die "policy: --verdict <high|medium|low> is required (or --mission <id>, to read Number One's own xo/verdict.json)."
  case "$verdict" in high|medium|low) ;; *) die "policy: '$verdict' is not a Number One verdict — high, medium or low." ;; esac
  case "$live" in
    pass|bugs) ;;
    "") die "policy: --live-check <pass|bugs> is required — it is half the table, and on the modelled weekend it decided every merge." ;;
    *)  die "policy: '$live' is not a live-check verdict — pass or bugs." ;;
  esac

  # S240 — NUMBER ONE NOW RECOMMENDS AN ACTION, so on the `pass` branch that
  # recommendation IS the answer and this table stops re-deriving it by hand
  # (doing it by hand on every look is the defect S240 closed). It is read only
  # when the live check passed: "the live check found bugs" still decides it,
  # whatever Number One said, because the live check is the other instrument and
  # Number One cannot see what it sees. THE FALLBACK STAYS — a verdict written
  # before S240, or one naming no recommendation, goes through the table below
  # exactly as it did.
  local rec=""
  if [ -n "$mission" ]; then
    rec="$(jfile "$MISSIONS/$mission/xo/verdict.json" recommendation)"
  fi

  local action why
  if [ "$live" = bugs ]; then
    action="send-back"
    why="the live check found bugs — that decides it, whatever Number One scored ($verdict)."
  elif [ "$rec" = merge ] || [ "$rec" = merge-with-follow-ups ] || [ "$rec" = send-back ]; then
    action="$(printf '%s' "$rec" | sed 's/merge-with-follow-ups/merge+follow-ups/')"
    local recwhy; recwhy="$(jfile "$MISSIONS/$mission/xo/verdict.json" recommendationWhy)"
    why="Number One recommended $rec off its own ledger${recwhy:+ — $recwhy}"
  else
    case "$verdict" in
      high)   action="merge";            why="Number One says high and the live check passed." ;;
      medium) action="merge+follow-ups"; why="Number One says medium and the live check passed — merge, and file the gaps it named as follow-ups." ;;
      low)
        case "$reason" in
          product)        action="send-back"; why="low for a PRODUCT reason — the work is not done, so it goes back." ;;
          infrastructure) action="override";  why="low for INFRASTRUCTURE reasons only (nothing about the product) — fix the cause, verify that point live, and record the override." ;;
          "") die "policy: a LOW verdict needs --reason product|infrastructure — the action depends entirely on it (product = send it back; infrastructure only = fix, verify live, record an override)." ;;
          *)  die "policy: '$reason' is not a reason — product or infrastructure." ;;
        esac
        ;;
    esac
  fi

  if [ "$action" = override ]; then
    [ -n "$evidence" ] || die "policy: an override needs --evidence <path> — an override with no evidence on disk is a shrug, and this one is going in the permanent ledger."
    local ev="$evidence"
    case "$ev" in /*) ;; *) ev="$CWD/$evidence" ;; esac
    [ -e "$ev" ] || die "policy: the --evidence path does not exist: $evidence. Write the live check that justifies the override first (that is the whole point of recording it)."
  fi

  say "ACTION: $action"
  say "WHY: $why"
  say "PLAYBOOK: $(policy_heading "$action")"
  policy_then "$action" "${mission:-<mission>}"

  if [ "$action" = override ]; then
    ledger_append overrides "$("$PY" - "${mission:-}" "$verdict" "$reason" "$evidence" "$note" <<'PY'
import json, sys
print(json.dumps({"kind": "verdict-override", "mission": sys.argv[1],
                  "verdict": sys.argv[2], "reason": sys.argv[3],
                  "evidence": sys.argv[4], "note": sys.argv[5],
                  "action": "merged over a low verdict"}))
PY
)" || die "policy: the overrides ledger refused the entry — the override is NOT recorded, so do not act on it."
    say ""
    say "RECORDED: the override is in $LCARS_DIR/autopilot-overrides.jsonl, with its evidence path."
  fi
  return 0
}

policy_heading() {
  case "$1" in
    merge|merge+follow-ups|override) printf '%s' "$PB_land" ;;
    *)                               printf '%s' "$PB_verify_gate" ;;
  esac
}

policy_then() { # <action> <mission>
  local m="$2"
  case "$1" in
    merge)
      say "THEN: $SELF land $m"
      ;;
    merge+follow-ups)
      say "THEN: file each gap Number One named as its own mission, then land:"
      say "  bash $SKILLS_DIR/lcars-file/file.sh --prd <follow-up.md>   # one per gap"
      say "  $SELF land $m"
      ;;
    send-back)
      say "THEN: send it back through LCARS's own verbs — never a second route to the same outcome:"
      say "  $SELF file-bug --parent $m --prd <bug-prd.md>    # one PRD per bug, AC #1 = Observed live:"
      say "  bash $SKILLS_DIR/lcars-resolve-logs/resolve-logs.sh --parent $m"
      say "  $SELF live-check $m --type <types>               # re-verify with DIFFERENT data"
      say "  bash $SKILLS_DIR/lcars-respond/respond.sh answer --mission $m --answer \"<the live evidence>\""
      say "  $SELF land $m"
      ;;
    override)
      say "THEN: fix the infrastructure cause, prove that one point live, then land:"
      say "  $SELF live-check $m --type <types>               # the point you fixed, with DIFFERENT data"
      say "  $SELF land $m"
      ;;
  esac
}

policy_table() {
  say "THE MERGE POLICY — one action per (Number One verdict, live check)"
  say ""
  printf '  %-26s %-12s %s\n' 'NUMBER ONE' 'LIVE CHECK' 'ACTION'
  printf '  %-26s %-12s %s\n' 'any'                      'bugs' 'send-back'
  printf '  %-26s %-12s %s\n' 'high'                     'pass' 'merge'
  printf '  %-26s %-12s %s\n' 'medium'                   'pass' 'merge+follow-ups'
  printf '  %-26s %-12s %s\n' 'low (product reason)'     'pass' 'send-back'
  printf '  %-26s %-12s %s\n' 'low (infrastructure only)' 'pass' 'override (recorded)'
  say ""
  say "  The live check decides: Number One scored every CLI or integration milestone"
  say "  low for reasons it could not reach, so a \`bugs\` live check sends back a high."
  say "  THE MERGE IS THE BUDDY'S CALL — this is the recommendation, and every"
  say "  override lands in autopilot-overrides.jsonl with the evidence path."
}

# ==========================================================================
# report — one page, from the records, with nothing from a clock
# ==========================================================================
# The captain reads this on his phone. It is rendered ONLY from what was
# written down (autopilot.json, the mission state, the live-check evidence dir,
# the overrides ledger), so a report that changes when nothing changed is
# impossible and the page can be reviewed.
cmd_report() {
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)   out="${2:-}"; shift 2 ;;
      --out=*) out="${1#--out=}"; shift ;;
      *)       die "report: unknown argument '$1'" ;;
    esac
  done
  require_state
  [ -n "$out" ] || out="$APDIR/report.html"
  mkdir -p "$(dirname "$out")"
  "$PY" - "$APJSON" "$MISSIONS" "$LCARS_DIR/autopilot-overrides.jsonl" "$out" <<'PY'
import json, os, sys

apj, missions_dir, ovl, out = sys.argv[1:5]
try:
    d = json.load(open(apj))
except Exception:
    d = {}
scope = d.get("scope") or []
ms = d.get("missions") or {}

def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def started_str(v):
    # `init` records startedAt as epoch SECONDS; a human-written one is already
    # an ISO string. Render an int readably (UTC, so it is the same on any box)
    # and pass a string through untouched: either way the same record renders
    # the same bytes, which is what makes this page reviewable.
    if v is None or v == "":
        return "-"
    if isinstance(v, int) or (isinstance(v, str) and v.isdigit()):
        import time
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(v)))
    return str(v)

def state(mid, key, default=""):
    try:
        return json.load(open(os.path.join(missions_dir, mid, "state.json"))).get(key) or default
    except Exception:
        return default

def verdict_of(mid):
    try:
        return (json.load(open(os.path.join(missions_dir, mid, "xo", "verdict.json")))
                .get("score") or "").strip()
    except Exception:
        return ""

def children(mid):
    out = []
    if not mid or not os.path.isdir(missions_dir):
        return out
    for name in sorted(os.listdir(missions_dir)):
        try:
            s = json.load(open(os.path.join(missions_dir, name, "state.json")))
        except Exception:
            continue
        if s.get("type") == "bug" and s.get("parentMission") == mid:
            out.append((name, s.get("title") or name, s.get("stage") or "?"))
    return out

def shots(mid):
    if not mid:
        return []
    p = os.path.join(missions_dir, mid, "live-check")
    if not os.path.isdir(p):
        return []
    return sorted(f for f in os.listdir(p)
                  if f.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".webp")))

# A shot's href is relative to WHEREVER THIS REPORT IS WRITTEN, not to the
# default report dir. The links used to be hardcoded `../missions/<id>/...`,
# which resolves only from $APDIR: under any other `--out` every screenshot
# link was dead, and a shot nobody can open is a shot nobody looked at, which
# is the one thing the live check exists to produce.
OUT_DIR = os.path.dirname(os.path.abspath(out))

def shot_href(mid, f):
    return os.path.relpath(
        os.path.join(os.path.abspath(missions_dir), mid, "live-check", f),
        OUT_DIR)

rows, shot_items, bug_items = [], [], []
for label in scope:
    mid = (ms.get(label) or {}).get("id") or ""
    stage = state(mid, "stage") if mid else ""
    v = verdict_of(mid) if mid else ""
    lc = (ms.get(label) or {}).get("liveCheck") or ""
    kids = children(mid)
    sh = shots(mid)
    vcell = "<td>%s</td>" % esc(v) if v else '<td class="none">-</td>'
    if lc:
        lcell = '<td class="%s">%s</td>' % (esc(lc), esc(lc))
    else:
        lcell = '<td class="none">-</td>'
    rows.append(
        '<tr id="row-%s"><td>%s</td><td>%s</td><td>%s</td>%s%s<td>%d</td><td>%d</td><td>%d</td></tr>'
        % (esc(label), esc(label), esc(mid or "(unfiled)"), esc(stage or "-"),
           vcell, lcell, len(sh), len(kids),
           sum(1 for k in kids if k[2] == "done")))
    for f in sh:
        shot_items.append('<li>%s <a href="%s">%s</a></li>'
                          % (esc(label), esc(shot_href(mid, f)), esc(f)))
    for cid, title, cstage in kids:
        bug_items.append('<li>%s %s &mdash; %s &mdash; %s</li>'
                         % (esc(label), esc(cid), esc(title), esc(cstage)))

ov_items = []
if os.path.exists(ovl):
    for line in open(ovl):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        bits = [o.get("mission") or "(no mission)"]
        vr = "/".join(x for x in (o.get("verdict"), o.get("reason")) if x)
        if vr:
            bits.append(vr.replace("/", " / "))
        if o.get("note"):
            bits.append(o["note"])
        bits.append("evidence: %s" % (o.get("evidence") or "(none recorded)"))
        ov_items.append("<li>%s</li>" % " &mdash; ".join(esc(b) for b in bits))

def ul(uid, items):
    body = "\n".join(items) if items else "<li>none yet</li>"
    return '<ul id="%s">\n%s\n</ul>' % (uid, body)

html = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Autopilot progress</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; max-width: 60rem; }
  table { border-collapse: collapse; width: 100%%; }
  td, th { border-bottom: 1px solid #ddd; padding: .4rem .6rem; text-align: left; }
  .pass { color: #0a7a2f; } .bugs { color: #c0392b; } .none { color: #888; }
  ul { padding-left: 1.2rem; }
  @media (max-width: 500px) { body { margin: .75rem; } }
</style></head>
<body>
<h1 id="report-title">Autopilot progress</h1>
<p id="report-meta">spec: %(spec)s &middot; started: %(started)s</p>
<table id="report-milestones">
<thead><tr><th>Milestone</th><th>Mission</th><th>Stage</th><th>Number One</th><th>Live check</th><th>Shots</th><th>Bugs filed</th><th>Bugs fixed</th></tr></thead>
<tbody>
%(rows)s
</tbody>
</table>
<h2 id="shots-title">Screenshots</h2>
%(shots)s
<h2 id="bugs-title">Bugs filed</h2>
%(bugs)s
<h2 id="overrides-title">Overrides recorded</h2>
%(overrides)s
</body></html>
""" % {
    "spec": esc(d.get("spec") or "(no spec recorded)"),
    "started": esc(started_str(d.get("startedAt"))),
    "rows": "\n".join(rows) if rows else '<tr><td colspan="8">nothing in scope yet</td></tr>',
    "shots": ul("shots", shot_items),
    "bugs": ul("bugs", bug_items),
    "overrides": ul("overrides", ov_items),
}
open(out, "w").write(html)
print(out)
PY
  local rc=$?
  [ "$rc" -eq 0 ] || die "report: the renderer failed"
  say "  per milestone: the stage, Number One's verdict, the live-check verdict, the shots, the bugs."
  say "  nothing on that page comes from a clock — re-render it and it is identical."
  return 0
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
  ask)         cmd_ask "$@" ;;
  drive)       cmd_drive "$@" ;;
  _waiter)     cmd_waiter "$@" ;;
  stalled)     cmd_stalled "$@" ;;
  land)        cmd_land "$@" ;;
  push-gated)  cmd_push_gated "$@" ;;
  worktree)    cmd_worktree "$@" ;;
  live-check)  cmd_live_check "$@" ;;
  workflow-run) cmd_workflow_run "$@" ;;
  file-bug)    cmd_file_bug "$@" ;;
  policy)      cmd_policy "$@" ;;
  report)      cmd_report "$@" ;;
  ledger)      cmd_ledger "$@" ;;
  heartbeat)   cmd_heartbeat "$@" ;;
  ''|-h|--help|help) usage ;;
  *)           printf 'lcars autopilot: unknown subcommand %s\n' "$SUB" >&2; usage ;;
esac
