#!/usr/bin/env bash
#
# ech.sh — the TOKEN-FREE driver behind `lcars eeh`'s Hologram Command Mode
# ("run it for me"). The judgement in that mode is prose the MODEL follows
# (HOLOGRAM-COMMAND-MODE.md); everything SEQUENCEABLE is here, and spends nothing.
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
#   ech.sh init --spec <path|url> [--scope M0,M1] [--engine copilot]
#                     [--deadline <iso>] [--force]
#   ech.sh status
#   ech.sh next [--all]
#   ech.sh drive <mission>
#   ech.sh stalled
#   ech.sh land <mission>
#   ech.sh push-gated
#   ech.sh worktree <mission> | worktree --branch <branch>
#   ech.sh live-check <mission> --type cli|web|workflow[,…]
#   ech.sh live-check done <mission> --verdict pass|bugs
#   ech.sh workflow-run <mission> <workflow.yml> [--evidence-dir <dir>]
#   ech.sh file-bug --parent <mission> --prd <bug-prd.md>
#   ech.sh policy --verdict high|medium|low [--reason product|infrastructure]
#                       --live-check pass|bugs [--mission <m>] [--evidence <path>]
#   ech.sh report [--out <path>]
#   ech.sh ledger feedback|overrides|decisions '<json>'
#   ech.sh heartbeat install|remove|status
#   ech.sh record <dotted.key> <value>
#   ech.sh answered <question-id|mission> ["<his answer>"]
#   ech.sh ask "<what>" --mission <m> [--why …] [--command …] [--rollback …]
#   ech.sh playbook
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
#   LCARS_ECH_CWD   the repo to operate on       (default $PWD)
#   LCARS_GIT_BIN         git                          (default git)
#   LCARS_PYTHON_BIN      python3                      (default python3)
#   LCARS_CRONTAB_BIN     crontab                      (default crontab)
#   LCARS_RUN_SCRIPT LCARS_APPROVE_SCRIPT LCARS_XO_SCRIPT LCARS_RESPOND_SCRIPT
#   LCARS_LOG_SCRIPT LCARS_FILE_SCRIPT LCARS_RESOLVE_LOGS_SCRIPT
#   LCARS_ESTABLISH_VISION_BIN                         (sibling skills)
#   LCARS_NOTIFY          the walk-away ping           (lcars-run/notify.sh)
#   LCARS_SELF_CMD        the name this driver calls itself in its own output
#                         (default: derived from $0, else `lcars-ech`)
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

# ==========================================================================
# THE NAME THIS DRIVER CALLS ITSELF IN ITS OWN OUTPUT (S277)
# ==========================================================================
# WHY THIS EXISTS. Every message below that tells a human or a model to run
# something used to spell it `ech.sh <verb>` — the FILE's name, which is
# not a command anywhere. `init` ended with "record the answers with
# `ech.sh record liveTargets.host <host>`" and a real Copilot turn told to
# follow it ran exactly that, took exit 127, stopped, and recorded nothing — on
# the very first step after `init`. `--help`'s usage header had the same bug, so
# the driver misnamed itself to everyone on both CLIs. The prose fix (HOLOGRAM-COMMAND-MODE.md
# naming `lcars-ech`) does not reach these: they are produced at runtime,
# with no note anywhere near them.
#
# WHY DERIVED, NOT HARD-CODED. A literal would drift the moment the launcher is
# renamed. So the name is taken from how this process was actually invoked, and
# only falls back to the on-PATH name install.sh generates.
#
# MEASURED CAVEAT — the derivation cannot see the launcher's name today.
# install.sh's generated wrapper is `exec bash "<abs>/ech.sh" "$@"`, which
# REPLACES $0 with the script's own path, so `basename "$0"` is `ech.sh`
# (the wrong name) and never `lcars-ech`. That is exactly the case the
# fallback below is for, and it is why the effective value is the PATH command.
# $LCARS_SELF_CMD is the seam: a future front door (or a test) can declare the
# name it was invoked as, and every message follows it with no string edits.
SELF_CMD="${LCARS_SELF_CMD:-}"
if [ -z "$SELF_CMD" ]; then
  SELF_CMD="$(basename -- "${0:-}" 2>/dev/null)"
  case "$SELF_CMD" in
    # the raw script, a shell, or nothing to go on -> the command install.sh makes
    *.sh|''|-*|bash|sh|dash|zsh|ksh) SELF_CMD="lcars-ech" ;;
  esac
fi

GIT_BIN="${LCARS_GIT_BIN:-git}"
# The forge CLI, env-injected so a suite can stub it (CLAUDE.md step 2). Added
# by the preflight forge-login check: no authenticated CLI, no pull request.
GH_BIN="${LCARS_GH_BIN:-gh}"
PY="${LCARS_PYTHON_BIN:-python3}"
CRONTAB_BIN="${LCARS_CRONTAB_BIN:-crontab}"

RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SKILLS_DIR/lcars-run/run.sh}"
APPROVE_SCRIPT="${LCARS_APPROVE_SCRIPT:-$SKILLS_DIR/lcars-approve/approve.sh}"
XO_SCRIPT="${LCARS_XO_SCRIPT:-$SKILLS_DIR/lcars-xo/xo.sh}"
RESPOND_SCRIPT="${LCARS_RESPOND_SCRIPT:-$SKILLS_DIR/lcars-respond/respond.sh}"
LOG_SCRIPT="${LCARS_LOG_SCRIPT:-$SKILLS_DIR/lcars-log/log.sh}"
NOTIFY_BIN="${LCARS_NOTIFY:-$SKILLS_DIR/lcars-run/notify.sh}"

die()  { printf 'lcars ech: %s\n' "$1" >&2; exit "${2:-1}"; }
say()  { printf '%s\n' "$1"; }

# The cheat sheet. The modelled run's two biggest token sinks were reading LCARS
# internals to find a verb's real flags, and long log greps. Both are answered
# here, on purpose, so nobody has to go and read run.sh to drive a mission.
usage() {
  # The header is printed SEPARATELY from the quoted heredoc below so the driver
  # can name itself as the reader must type it ($SELF_CMD). The heredoc stays
  # single-quoted on purpose: its body is full of backticks and `$`-looking
  # examples that must print literally, and a suite check proves that.
  printf 'Usage: %s <subcommand> [args]   (playbook: HOLOGRAM-COMMAND-MODE.md — print it with `lcars-eeh docs ech`)\n' "$SELF_CMD" >&2
  cat >&2 <<'USAGE'

  init --spec <path|url> [--scope M0,M1] [--engine <e>] [--deadline <iso>] [--force]
                       write .git/lcars/autopilot.json (refuses to overwrite without --force)
                       ...and then runs `preflight`, below, while you are still here
  preflight            the ONE round of setup questions, each with a RECOMMENDED
                       default so "yes" answers the block. With NO terminal it never
                       waits: it prints what it would have asked and the value it
                       proceeds on, or stops deliberately (exit 10) on the one
                       prerequisite nobody can default — nowhere to push
  status               one screen: scope, stages, gates, slots, EVERY open question, next action
  next [--all]         the ONE next mechanical step, and the HOLOGRAM-COMMAND-MODE.md heading for it
  playbook             the action -> heading table the contract test locks
  record <k.k> <v>     write one key (JSON value if it parses; empty value deletes)
  answered <id> "<a>"  close ONE open question (ids come from `status`); never deletes it
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
                       --branch needs no ECH record (Number One passes it)
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
  exec <skill>/<script> [args]
                       run a sibling skill's script from THIS clone (resolved beside
                       this driver, so it works under either CLI's install mount)

THE TWO CAPS THIS DRIVER ENFORCES: two parallel missions, and three failed
drives of the same mission (then it asks the captain instead of retrying).
USAGE
  # Printed separately so the prefix follows $SELF_CMD: NONE of the tokens below
  # is runnable on its own -- each is an `exec` argument. The header said nothing
  # about that, so a model copying a line took exit 127 (S277).
  printf '\nTHE VERBS THIS DRIVES (run any of them with `%s exec <skill>/<script>` — their real flags\n' "$SELF_CMD" >&2
  printf '                       — do not guess, and do not re-implement):\n' >&2
  cat >&2 <<'USAGE'
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
CWD="${LCARS_ECH_CWD:-$PWD}"
[ -d "$CWD" ] || die "no such directory: $CWD"
CWD="$(cd "$CWD" && pwd)"
GITDIR="$CWD/.git"
[ -e "$GITDIR" ] || die "$CWD is not a git repository — the ECH operates on a repo."
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
    sys.stderr.write("the ECH: %s exists but is NOT valid JSON - refusing to overwrite it\n" % f)
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
# by hand — the old HOLOGRAM-COMMAND-MODE.md § 9 instructed exactly that — with nothing
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
# verb — `ech.sh ask`, or `write_pending` from inside the driver — and
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
  [ -f "$APJSON" ] || die "no autopilot.json in $LCARS_DIR — run \`$SELF_CMD init --spec <path>\` first."
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
# THE PLAYBOOK TABLE — the contract between this script and HOLOGRAM-COMMAND-MODE.md.
# `next` emits one of these actions and cites its heading; the suite asserts
# every heading exists VERBATIM in the installed HOLOGRAM-COMMAND-MODE.md. Rename a heading
# and the suite fails; add an action with no prose behind it and it fails too.
# ==========================================================================
PB_align='## 1. The alignment round — one batch of questions, then walk away'
PB_captain_step='## 2. Captain-only steps, collected up front'
PB_foundation='## 3. Foundation — establish the vision, then re-check the test command'
PB_holodeck='## 4. File a milestone through the front door'
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
    holodeck)       printf '%s' "$PB_holodeck" ;;
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
  for a in align captain-step foundation holodeck file drive verify-gate land wait answer-pending done; do
    printf '%s\t%s\n' "$a" "$(playbook_heading "$a")"
  done
}

# ==========================================================================
# preflight — THE SETUP QUESTIONS, ASKED WHILE A HUMAN IS STILL THERE
# ==========================================================================
# THE DEFECT THIS CLOSES. The driver used to discover what it needed at the
# moment it failed, not at the start. On 2026-10-14/15 THREE overnight runs died
# at verification waiting on a permission nobody was awake to give, and a FOURTH
# could not open a pull request because the repo had no remote — a fact LCARS had
# ALREADY written into the mission's own state.json (`githubIssue: null`) and
# never surfaced at the gate, because the gate re-derived its own view of the
# world instead of reading the record. From outside, a blocked run and a healthy
# idle one are indistinguishable, and NOTHING INSIDE THE RUN CAN DETECT OR
# RECOVER FROM IT. The cost is the rest of the night, every time.
#
# THE MODEL IS THE DEPENDENCY SWEEP night-watch does while he is still awake:
# ask ONCE, compactly, every question with a RECOMMENDED default in bold so
# "yes to all" is a valid answer. He is trying to go to bed.
#
# WITH NOBODY THERE IT DECIDES, IT NEVER WAITS. Two outcomes are legal per
# question and the choice is made per question, on purpose:
#   PROCEED on a stated default — where the default destroys nothing and
#     stopping the night over it would waste the night (questions 1 and 2).
#   STOP deliberately, recording a real captain question — where there is
#     nothing honest to invent and the run would die at the gate anyway
#     (question 3: no remote means no push and no PR, full stop).
# Proceeding SILENTLY is never one of them: every defaulted question prints the
# question it would have asked and the value it took.
#
# HOW "NOBODY IS THERE" IS DETECTED, AND WHAT THAT MISSES. All THREE of these
# must hold before anything is asked, and they are tested deepest-first so the
# reason it prints is the most informative one that is true:
#   1. `/dev/tty` opens — this process has a CONTROLLING TERMINAL. Answers are
#      read from there, never from stdin, which belongs to the caller.
#   2. `[ -t 0 ]` — stdin is a terminal and has not been redirected.
#   3. WE ARE THE TERMINAL'S FOREGROUND PROCESS GROUP — the terminal's `tpgid`
#      is our own `pgid`. Only the foreground group may READ the terminal.
#
# THE THIRD ONE IS THE ONE THAT MATTERED, AND IT WAS MEASURED. With 1 and 2
# alone, `bash ech.sh init … &` from a terminal — a plain `&`, which is
# the `nohup`/detached-tmux shape AND the shape ORCHESTRATION.md tells the
# captain to use — printed question 1, was stopped by SIGTTIN, and sat in
# process state `T` for the full 60s of observation: no output, no progress, no
# exit. A background job SATISFIES both 1 and 2; what it cannot do is *read*
# without the kernel stopping it. That is precisely "a blocked run and a healthy
# idle run look identical from outside", reintroduced by the fix for it, so the
# foreground test is not an optimisation — it is the whole point.
#
# AND SIGTTIN IS IGNORED FOR THE DURATION OF THE ROUND (`cmd_preflight`), so
# even a case the three tests cannot see cannot STOP this process: with SIGTTIN
# ignored the read FAILS instead, and a failed read already falls through to the
# nobody-is-there decision. Detection first, the signal second, the bounded read
# third — three independent reasons the round always comes back.
#
# BOTH OF THE FIRST TWO, AND THE SECOND ONE WAS LEARNED THE HARD WAY. The first
# cut of this used /dev/tty ALONE, on the reasoning that `init | tee` has a human
# right there. tests/harness.test.sh runs every suite from a pty with stdin OPEN
# on purpose, `tests/lcars-eeh.test.sh` invokes `init`, and that suite went
# from 5.9s to ELAPSED 120.0s — exactly the read bound — and was killed by the
# cage. A BOUNDED read turns a hang into a long hang; it does not stop it being
# one. This repo's standing convention is that a command run with stdin closed
# is unattended -- the full test gate invokes every suite that way, on purpose --
# and a question-asking step has to honour it or every suite becomes a hang
# risk. (A suite check forbids naming that gate script here, so it is described
# rather than spelled: see CLAUDE.md step 4.)
# `init | tee` still asks, because `| tee` redirects stdout, not stdin, and a
# pipeline runs in the shell's FOREGROUND group.
#
# WHAT IT STILL GETS WRONG. A detached session that KEEPS its terminal and is
# its own foreground group — `setsid` with a tty handed to it, a tmux pane the
# captain left attached and walked away from — reads as attended, which is why
# every read is BOUNDED ($LCARS_ECH_ASK_TIMEOUT, default 120s) and one
# unanswered question settles the whole block as "nobody is here". The other
# direction: `init < answers.txt` reads as unattended although a human wrote
# that file, and a CI runner reads as unattended, which is the right call here
# but is NOT the same thing as a detached daemon.
ASK_TIMEOUT="${LCARS_ECH_ASK_TIMEOUT:-120}"
PF_TTY=0
PF_VALUE=""
PF_YES_TO_ALL=0
PF_ASKED=0
PF_STOPS=0
PF_BOLD=""
PF_NORM=""
# WHY nothing could be asked, in his words, printed instead of a guess. The old
# banner said "there is no /dev/tty to ask on" for every case, which is simply
# FALSE when stdin was merely redirected and false again for a background job.
PF_NO_TTY_WHY="nobody is there to ask"
# Set by `pf_settled`: the id of the question the captain has already answered.
PF_SETTLED_ID=""

# THE BOUND ON EVERY PROBE THAT LEAVES THIS MACHINE. A reachability check that
# can hang is worse than no reachability check: it becomes the exact failure it
# was added to detect. There is no portable `timeout(1)` on macOS (this box has
# none), so `pf_bounded` below is the bound.
PROBE_TIMEOUT="${LCARS_ECH_PROBE_TIMEOUT:-15}"

# THE SENTINEL for question 2's default. It is a PHRASE, never a command, and it
# is never written to `testCommand`: `push-gated` eval's that string, and a
# guessed suite is strictly worse than none (it either refuses every push or
# passes vacuously and pushes red, which is the exact bug `push-gated` exists
# for).
PF_TC_FOUNDATION='leave it to the foundation step'

# ==========================================================================
# THE LEDGER KEYS — one constant per prerequisite preflight can STOP on
# ==========================================================================
# A question's `what` is BOTH the dedupe key (`write_pending`, over the open
# set) and the withdrawal key (`ap_withdraw`), so it is a CONSTANT and every
# detail that varies — a URL, a spelling, a mission id — lives in `why`. Put the
# remote's URL in one of these and a cured prerequisite can no longer find its
# own question to retire, which is defect 2 of fix 4 all over again.
PF_Q_NOPUSH='there is nowhere to push: this repo has no origin remote, so nothing can be pushed and no pull request can be opened.'
PF_Q_UNREACHABLE='the push remote does not answer: git cannot reach `origin`, so the push and the pull request both die at the gate.'
# A DEADLINE IS NOT A REFUSAL, so it is not the same question (S300 fix1).
# MEASURED: an `ext::` origin that answers correctly in 25.2s (`git ls-remote
# origin` → EXIT 0, refs returned — a cold VPN handshake, a monorepo's huge ref
# advertisement, a loaded forge) was reported as "The remote does NOT answer",
# with a body blaming "a deleted repo, a typo'd host and revoked auth" and
# advice to "fix the URL or the auth". Every word of that is FALSE for a healthy
# slow remote, and the `what` is the line his inbox shows him first. It is also
# the ONE stop that can never retire itself — a slow remote stays slow — so the
# wording has to carry the settle route rather than a diagnosis it cannot
# support.
PF_Q_SLOW_REMOTE='the push remote did not answer inside the probe deadline: it may simply be slow rather than wrong, and only you can tell which.'
PF_Q_FORGE_LOGIN='the forge CLI is not logged in, so no pull request can be opened however well the run builds.'
PF_Q_ALLOW_ALL='the engine has no unattended permission: COPILOT_ALLOW_ALL is not exactly `true`, so an unattended copilot run is refused on every command.'
PF_Q_NO_LAUNCH_DIR='there is nowhere to make the launch copies: no writable directory could be found for the throwaway worktrees every live check runs from.'

# pf_bounded <secs> <cmd…> → the command's rc, or 124 if it outran <secs>.
#
# WHY IT EXISTS. The two checks below talk to the NETWORK, and an unreachable
# host, a half-open connection or a credential helper waiting on a GUI answer
# are all unbounded. There is no portable `timeout(1)` on macOS and this box has
# none, so the bound is built here. 124 is `timeout(1)`'s own convention for
# "outran the deadline", so a caller can tell that from a refusal.
#
# IT BLOCKS ON THE PROCESS, it does not poll it. A separate watchdog owns the
# clock and the main path is a plain `wait`, which is this script's standing rule
# for every spawn (the waiter is held to the same one). The watchdog LEAVES A
# MARK before it kills, because "the child was signalled" and "the deadline
# fired" are otherwise the same 137 to the reader — and an instrument must not
# state a conclusion it cannot support.
#
# IT KILLS THE PROCESS GROUP, NOT THE CHILD (S300 fix3). MEASURED: against an
# https black hole the bound returned on time and left
# `git-remote-https origin https://10.255.255.1/x.git` alive at `ppid 1`, still
# there 50s later, drifting toward libcurl's ~300s connect timeout. `git
# ls-remote` execs a TRANSPORT HELPER, and the old kill reached the direct child
# and its direct children only; anything one level deeper survived, re-parented
# to init. Reproduced on a slow (healthy) remote too, so it is the bound-kill
# path and not an https quirk. A `ppid 1` orphan outlives the cage and corrupts
# every later process measurement (`harness` 7b asserts zero of them), so the
# whole spawn now runs under `set -m` in a subshell: monitor mode gives the job
# its OWN process group, which `kill -9 -$p` then takes out wholesale. The
# watchdog's own group goes the same way, which also stops its `sleep` from
# outliving it — the second orphan nobody had attributed.
#
# AND THE SUBSHELL'S STDERR IS CLOSED ON PURPOSE (S300 fix4). MEASURED: bash's
# job-control notification — `ech.sh: line 740: 93081 Killed: 9 "$@" >
# /dev/null 2>&1 < /dev/null` — landed in the middle of the captain's report,
# between items 3 and 3b, exposing an internal line number and a raw `"$@"` and
# reading like a crash to a human at 03:00. The notification is printed by the
# shell that REAPS the job, so the job is reaped inside a subshell whose stderr
# is discarded. The commands themselves were already fully redirected, so
# nothing legible is lost.
pf_bounded() {
  local secs="$1"; shift
  local mark; mark="$(mktemp "${TMPDIR:-/tmp}/lcars-pf-bound.XXXXXX")"
  rm -f "$mark"
  local rc=0
  (
    set -m
    "$@" >/dev/null 2>&1 </dev/null &
    local p=$!
    # THE WHOLE GROUP: `git ls-remote` execs a transport helper (and over ssh an
    # `ssh` of its own), and killing only the parent leaves it holding the
    # socket open until the TCP stack gives up — minutes later, at `ppid 1`.
    # `kill -9 -$p` is the group; the two narrower kills stay as belt and braces
    # for anything that left the group on its own.
    ( sleep "$secs"; : >"$mark"
      kill -9 -"$p" >/dev/null 2>&1
      pkill -9 -P "$p" >/dev/null 2>&1
      kill -9 "$p" >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
    local w=$!
    local crc=0
    wait "$p" || crc=$?
    kill -9 -"$w" >/dev/null 2>&1 || true
    kill -9 "$w" >/dev/null 2>&1 || true
    wait "$w" 2>/dev/null || true
    exit $crc
  ) 2>/dev/null
  rc=$?
  if [ -f "$mark" ]; then
    rm -f "$mark"
    return 124
  fi
  rm -f "$mark"
  return $rc
}

# pf_remote_is_forge <url> — is there a forge at the other end to log in to?
# A local path or a `file://` url is a real remote that can be pushed to and has
# no account, so question 4 must not stop on it.
pf_remote_is_forge() {
  case "$1" in
    http://*|https://*|ssh://*|git://*|*@*:*) return 0 ;;
    *) return 1 ;;
  esac
}

# pf_answer_means_local_only <answer> — does this answer, in HIS words, mean
# "don't push"? THE ONE PLACE that decides, because two copies of this list
# would drift and the drift IS the defect below.
#
# The old reader matched the four exact spellings of `local` and nothing else,
# so "ship local-only, no push" — a perfectly clear instruction, and the one a
# man types on his phone — fell through to `git remote add origin "ship
# local-only, no push"`.
pf_answer_means_local_only() {
  local low; low="$(printf '%s' "${1-}" | tr 'A-Z' 'a-z')"
  case "$low" in
    local|local-only|local_only|*'local-only'*|*'local only'*|*'locally'*|*'no push'*|*'not push'*|*"don't push"*|*'nothing to push'*) return 0 ;;
    *) return 1 ;;
  esac
}

# pf_local_only_recorded — is this run, by the captain's own record, a run that
# never pushes? (S300 fix2)
#
# MEASURED: an https origin with the forge CLI logged out raised BOTH the push
# question and the forge-login question. `answered q1 "ship local-only, no push"`
# cleared the first and the next preflight STILL stopped on the login — so the
# offline/train/local-only case cost TWO commands, against a playbook that
# promises one. And it contradicted the login check's own stated scope ("skipped
# when … a run recorded as local-only"): a question answered *local-only* is the
# plainest possible record of that intent, and the check never read it.
#
# Three records mean the same thing, and all three count: `push.mode` (written
# by `pf_apply_push_answer` or by `record localOnly`), and a settled answer to
# EITHER push question in his own words — the unreachable-remote one included,
# because "it's unreachable, ship local-only" is the same decision.
# It names the record it found in $PF_LOCAL_ONLY_WHY, because a check that
# skips something has to say on whose authority.
PF_LOCAL_ONLY_WHY=""
pf_local_only_recorded() {
  PF_LOCAL_ONLY_WHY=""
  if [ "$(ap_j push.mode)" = "local-only" ]; then
    PF_LOCAL_ONLY_WHY="push.mode is recorded as local-only"
    return 0
  fi
  local q
  for q in "$PF_Q_NOPUSH" "$PF_Q_UNREACHABLE" "$PF_Q_SLOW_REMOTE"; do
    if pf_settled "$q" && pf_answer_means_local_only "$PF_SETTLED"; then
      PF_LOCAL_ONLY_WHY="you answered [$PF_SETTLED_ID] \"$PF_SETTLED\""
      return 0
    fi
  done
  return 1
}

# pf_remote_reachable <remote> → 0 reachable | 2 reachable but has NO refs yet
#                                124 it outran the bound | anything else: no
#
# A NAME IS NOT A REACHABILITY CHECK, AND THAT WAS MEASURED. `git remote
# get-url` only proves a line of config exists: pointed at
# `https://github.invalid.example/nope/nope.git` and at a dead local path, the
# old check printed "Somewhere to push: origin -> … — not asking" and returned
# in 0.4s, which is itself the proof it never spoke to the other end. A deleted
# repo, a typo'd host and revoked auth all leave that config line intact and die
# at the pull-request gate at 03:00 — the fourth dead night's exact class.
# `ls-remote` is the cheapest call that actually reaches the far side.
#
# EVERY INTERACTIVE DOOR IS SHUT, and the obvious one is not the one that bites:
# git PREFERS $GIT_ASKPASS over the terminal, so GIT_TERMINAL_PROMPT=0 ALONE was
# measured still hanging (600.1s in one case — the trace is in
# lcars-version/check.sh). These four muzzles are that file's shape, plus ssh
# BatchMode for a `git@` remote, plus `pf_bounded` over the lot.
pf_remote_reachable() {
  local rc
  pf_bounded "$PROBE_TIMEOUT" env \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= \
    GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=5' \
    "$GIT_BIN" -C "$CWD" -c core.askPass= ls-remote --exit-code "$1"
  rc=$?
  # `--exit-code` says 2 for "no matching refs", which on a bare `ls-remote` is
  # an EMPTY remote — a brand-new forge repo. It answered, so it is reachable.
  return $rc
}

# pf_dir_usable <path> — can a throwaway worktree actually be made under it?
#
# ASKING EARLY IS THE WHOLE POINT, so an answer that cannot work has to be
# caught while he is still in the room. Measured: `/nonexistent/…`,
# `/System/Library` (real, unwritable) and a bare `ok` — recorded verbatim as a
# RELATIVE launchDir — were all accepted, and each one fails hours later inside
# `worktree`, with nobody there.
pf_dir_usable() {
  local d="$1"
  case "$d" in /*) ;; *) return 1 ;; esac
  # The nearest EXISTING ancestor decides it: a directory that is not there yet
  # is fine so long as it can be created.
  while [ -n "$d" ] && [ "$d" != / ] && [ ! -d "$d" ]; do
    d="${d%/*}"
    [ -n "$d" ] || d=/
  done
  [ -d "$d" ] && [ -w "$d" ]
}

# ==========================================================================
# ap_withdraw — a prerequisite that is NOW SATISFIED retires its OWN question
# ==========================================================================
# THE DEFECT. After `git remote add origin …`, preflight printed `proceeding`
# while `status` still showed `open questions: 1 [q5] … this repo has no origin
# remote` and `next` said `answer-pending`. The captain had to hand-answer a
# question that was no longer true to unstick a run that was already unstuck.
# The cure is not a sixth careful reader: the check that RAISED the question is
# the one thing that knows the prerequisite is cured, so it is the thing that
# retires it — keyed on the same `what` the raise path dedupes on.
#
# IT NEVER DELETES, exactly like `answered`: the question stays on the record
# with the withdrawal beside it. `withdrawnAt` is what stops a withdrawal from
# ever reading as the captain's own decision (see `pf_settled`), so a
# prerequisite that breaks, is cured, and then breaks AGAIN earns a real new
# question instead of silently proceeding on a retirement note.
#
# IT DOES NOT NOTIFY. `write_pending` holds this script's ONE notify call site;
# retiring a question is not a new event for the captain.
ap_withdraw() { # <what> <reason> → prints the ids it retired, space-joined
  [ -f "$APJSON" ] || return 0
  ap_lock
  "$PY" - "$APJSON" "$1" "$2" "$(now)" <<'PY'
import json, os, sys
f, what, reason, ts = sys.argv[1:5]
try:
    d = json.load(open(f))
except Exception:
    sys.exit(0)
qs = d.get("questions")
if not isinstance(qs, dict):
    sys.exit(0)
hit = []
for k in sorted(qs):
    q = qs[k]
    if isinstance(q, dict) and not q.get("answeredAt") and q.get("what") == what:
        q["answeredAt"] = int(ts)
        q["withdrawnAt"] = int(ts)
        q["answer"] = reason
        hit.append(q.get("id") or k)
if not hit:
    sys.exit(0)
d["questions"] = qs
openq = [q for q in qs.values() if isinstance(q, dict) and not q.get("answeredAt")]
openq.sort(key=lambda q: (q.get("raisedAt") or 0, q.get("id") or ""))
d["pending"] = dict(openq[0]) if openq else {}
tmp = f + ".tmp.%d" % os.getpid()
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, f)
sys.stdout.write(" ".join(hit))
PY
  ap_unlock
  return 0
}

# pf_withdraw_say <what> <reason> — withdraw, and SAY SO when something moved.
# Silent when there was nothing open, so a healthy repo gains no noise.
pf_withdraw_say() {
  local ids; ids="$(ap_withdraw "$1" "$2")"
  [ -n "$ids" ] || return 0
  say "   WITHDRAWN [$ids]: that prerequisite is satisfied now, so its question is"
  say "   closed on the record — you do not have to answer a question that is no"
  say "   longer true to unstick your own run."
  return 0
}

# pf_settled <what>
#   rc 0  he HAS answered this exact question: $PF_SETTLED is his answer and
#         $PF_SETTLED_ID is the question's id
#   rc 1  he never has
# It sets GLOBALS rather than echoing, for the reason `pf_prompt` carries the
# same note: a `$(…)` caller would run the whole thing in a subshell and lose
# the id every time.
#
# THE ESCAPE HATCH THE TOOL PRINTS HAS TO WORK. preflight and HOLOGRAM-COMMAND-MODE.md both
# promise "settle it with `answered <id> …`, or fix the cause". Measured: the
# answer was recorded and then NOTHING READ IT, so the next preflight minted a
# byte-identical clone — `write_pending`'s dedupe is over the OPEN set only, by
# design, because a problem that RECURS after he answered is a real new event.
# Four attempts produced q1, q2, q3, q4, q5: one question, five times, in the
# inbox of a man answering from his phone. That is the interrupt-budget
# violation § 9 forbids. His answer is now CONSUMED — on a prerequisite
# preflight cannot default, his recorded decision is the authority, and it is
# read BEFORE anything is raised.
pf_settled() {
  PF_SETTLED=""
  PF_SETTLED_ID=""
  [ -f "$APJSON" ] || return 1
  local out
  out="$("$PY" - "$APJSON" "$1" <<'PY'
import json, sys
f, what = sys.argv[1:3]
try:
    d = json.load(open(f))
except Exception:
    sys.exit(0)
qs = (d.get("questions") or {})
best = None
for k in sorted(qs):
    q = qs[k]
    if not isinstance(q, dict):
        continue
    # A WITHDRAWAL IS NOT A DECISION: preflight wrote that answer itself.
    if q.get("withdrawnAt"):
        continue
    if q.get("what") != what or not q.get("answeredAt"):
        continue
    if not q.get("answer"):
        continue
    if best is None or (q.get("answeredAt") or 0) >= (best.get("answeredAt") or 0):
        best = q
if best is None:
    sys.exit(0)
sys.stdout.write("%s\n%s" % (best.get("id") or "?",
                             (best.get("answer") or "").replace("\n", " ")))
PY
)"
  [ -n "$out" ] || return 1
  PF_SETTLED_ID="$(printf '%s' "$out" | sed -n '1p')"
  PF_SETTLED="$(printf '%s' "$out" | sed -n '2,$p')"
  [ -n "$PF_SETTLED" ] || return 1
  return 0
}

# pf_stop <what> <why> <command> <rollback>
#   rc 0  it STOPPED: PF_STOPS is up and the question is on the record
#   rc 1  the captain had ALREADY ANSWERED this exact question — nothing was
#         raised and nothing stopped. His answer is echoed by the caller from
#         $PF_SETTLED / $PF_SETTLED_ID.
#
# EVERY deliberate stop goes through here, so "settleable" and "never minted
# twice" are properties of ONE path rather than four call sites that each have
# to remember. `write_pending` behind it keeps the (mission, what) dedupe over
# the open set, the single notify site, and the printed `answered <id>` line.
PF_SETTLED=""
pf_stop() {
  if pf_settled "$1"; then
    return 1
  fi
  PF_STOPS=$((PF_STOPS + 1))
  write_pending "-" "$1" "$2" "$3" "$4"
  return 0
}

# pf_in_foreground — are we the terminal's FOREGROUND process group? Only that
# group may read the terminal; any other is stopped with SIGTTIN the moment it
# tries. `ps -o tpgid=` is the shell-visible `tcgetpgrp()`.
#
# IT FAILS OPEN ON PURPOSE. If `ps` cannot answer (no such field, no such
# process, a stripped container) this returns 0 — "assume foreground" — because
# the other two defences are still there: SIGTTIN is ignored for the round, so
# the read fails rather than stopping us, and the read is bounded besides. An
# instrument that cannot measure must not invent a verdict.
pf_in_foreground() {
  local fg mine
  fg="$(ps -o tpgid= -p $$ 2>/dev/null | tr -d ' ')"
  mine="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  case "$fg" in ''|*[!0-9-]*) return 0 ;; esac
  case "$mine" in ''|*[!0-9]*) return 0 ;; esac
  PF_FG_PGID="$fg"; PF_MY_PGID="$mine"
  # -1 is "this terminal has no foreground group", i.e. nobody can read it.
  [ "$fg" != "-1" ] || return 1
  [ "$fg" = "$mine" ]
}
PF_FG_PGID=""
PF_MY_PGID=""

# pf_tty_present — is there a human to ask? See the header for all THREE halves
# and for what they still miss. Sets $PF_NO_TTY_WHY on every `no`.
pf_tty_present() {
  # THE DEEPEST FACT FIRST, so the printed reason is the most informative one
  # that is true. A detached daemon has no controlling terminal AND a redirected
  # stdin; saying "stdin is a redirect" about it is true and useless. All three
  # must hold either way, so the order changes only what it tells him.
  if ! ( exec 3<>/dev/tty ) 2>/dev/null; then
    PF_NO_TTY_WHY="there is no /dev/tty: this process has no controlling terminal at all"
    return 1
  fi
  if [ ! -t 0 ]; then
    PF_NO_TTY_WHY="stdin is not a terminal (a redirect or a pipe), which this repo reads as unattended"
    return 1
  fi
  if ! pf_in_foreground; then
    PF_NO_TTY_WHY="this is a BACKGROUND job (the terminal's foreground group is ${PF_FG_PGID:-?}, ours is ${PF_MY_PGID:-?}) — reading the terminal would stop it with SIGTTIN and it would never come back"
    return 1
  fi
  return 0
}

# pf_prompt <question> <recommended> → sets PF_VALUE
#   rc 0  a value was chosen (typed, or the RECOMMENDED default he accepted)
#   rc 1  NOBODY ANSWERED — no terminal, the read ran out, or he returned on a
#         question that has no honest default. The CALLER then decides whether
#         to proceed or stop, and must never loop back and ask again.
# It sets a GLOBAL rather than echoing: a `$(…)` call would put the whole thing
# in a subshell and lose PF_ASKED and PF_YES_TO_ALL on every question.
pf_prompt() {
  local q="$1" rec="$2" ans=""
  PF_VALUE=""
  [ "$PF_TTY" = 1 ] || return 1
  # "yes to all" already said: take this default with no further prompt.
  if [ "$PF_YES_TO_ALL" = 1 ] && [ -n "$rec" ]; then PF_VALUE="$rec"; return 0; fi
  {
    printf '\n%s\n' "$q"
    if [ -n "$rec" ]; then
      printf '   RECOMMENDED: %s%s%s\n' "$PF_BOLD" "$rec" "$PF_NORM"
      printf '   [return] takes it; "yes" takes every remaining RECOMMENDED default.\n'
    else
      printf '   NO RECOMMENDATION — there is nothing here that is honest to guess.\n'
    fi
    printf '> '
  } >/dev/tty 2>/dev/null
  PF_ASKED=$((PF_ASKED + 1))
  if ! IFS= read -r -t "$ASK_TIMEOUT" ans </dev/tty 2>/dev/null; then
    # A TERMINAL WITH NOBODY BEHIND IT — the case detection cannot see. One
    # unanswered question settles the whole block, because three timeouts in a
    # row buy three times the delay for the same conclusion.
    #
    # IT MAY ALSO HAVE FAILED INSTANTLY, so the message no longer asserts the
    # timeout. With SIGTTIN ignored (see `cmd_preflight`) a background job's read
    # RETURNS AN ERROR instead of stopping the process, which is the whole point
    # of ignoring it — and saying "nobody answered inside 120s" about a read that
    # failed in a millisecond is a measurement the line cannot support.
    PF_TTY=0
    PF_ASKED=$((PF_ASKED - 1))
    say ""
    say "   NOBODY ANSWERED (the read came back with nothing, inside its ${ASK_TIMEOUT}s"
    say "   bound or because the terminal refused it) — taking that as nobody being here."
    return 1
  fi
  case "$ans" in
    y|Y|yes|YES|Yes|a|A|all|ALL|'yes to all') PF_YES_TO_ALL=1; ans="" ;;
  esac
  if [ -z "$ans" ]; then
    # Return on a question with no recommendation is NOT an answer.
    [ -n "$rec" ] || return 1
    PF_VALUE="$rec"
    return 0
  fi
  PF_VALUE="$ans"
  return 0
}

# pf_missions_without_issue → the ids LCARS ITSELF recorded as having no forge
# issue, comma-joined. RECORD, DON'T INFER: `githubIssue: null` in a mission's
# own state.json is LCARS saying it had no forge to reach. The gate that could
# not open a PR re-derived its own view and never read this line.
pf_missions_without_issue() {
  [ -d "$MISSIONS" ] || return 0
  "$PY" - "$MISSIONS" <<'PY'
import json, os, sys
root = sys.argv[1]
out = []
try:
    names = sorted(os.listdir(root))
except OSError:
    sys.exit(0)
for n in names:
    p = os.path.join(root, n, "state.json")
    if not os.path.isfile(p):
        continue
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if d.get("stage") == "done":
        continue
    # The KEY MUST BE PRESENT and null. An absent key is a mission filed before
    # the field existed, which says nothing either way; null is a statement.
    if "githubIssue" in d and d["githubIssue"] is None:
        out.append(d.get("id") or n)
sys.stdout.write(", ".join(out))
PY
}

# --- question 1: where the launch copies go --------------------------------
# PROCEEDS on its default with nobody there. A throwaway directory overwrites
# nothing and is trivially defaultable; stopping a night over it would be the
# very waste this preflight exists to prevent.
pf_q_launch_dir() {
  local rec recorded
  recorded="$(ap_j launchDir)"
  if [ -n "$recorded" ]; then
    say ""
    say "1. Where the launch copies go: already recorded ($recorded) — not asking."
    pf_withdraw_say "$PF_Q_NO_LAUNCH_DIR" "withdrawn by preflight: launchDir is recorded as $recorded."
    return 0
  fi
  rec="${TMPDIR:-/tmp}"
  rec="${rec%/}"
  if pf_prompt "1. Where do the launch copies go? Every live check runs from a throwaway worktree and a throwaway HOME made under this directory." "$rec"; then
    # AN ANSWER THAT CANNOT WORK IS NOT AN ANSWER. Checked while he is in the
    # room, which is the whole reason this round happens here. It is NOT re-asked
    # (`pf_prompt`'s contract forbids looping back): the vetted default is taken
    # instead and said out loud, which is this question's standing character.
    if pf_dir_usable "$PF_VALUE"; then
      ap_set launchDir "$PF_VALUE"
      say ""
      say "1. Where the launch copies go: recorded launchDir = $PF_VALUE"
      pf_withdraw_say "$PF_Q_NO_LAUNCH_DIR" "withdrawn by preflight: launchDir is now $PF_VALUE."
      return 0
    fi
    say ""
    # TWO REFUSALS, TWO REMEDIES (S300 fix5). Both reasons used to print the
    # same advice — "re-run preflight after `mkdir -p <dir>`" — which is the fix
    # for a MISSING directory and the wrong fix for a relative one: nothing is
    # missing there, the path is merely ambiguous, and `mkdir -p ok` would
    # "succeed" and leave the same refusal in place.
    case "$PF_VALUE" in
      /*)
        say "1. Where the launch copies go: $PF_VALUE is NOT WRITABLE (nor is the nearest"
        say "   directory above it that exists), so no worktree could be made there."
        say "   NOT RECORDED. Taking the default instead: $rec"
        say "   (make it writable — or \`mkdir -p $PF_VALUE\` if it is simply not there —"
        say "    then re-run \`$SELF_CMD preflight\`, or set it directly with"
        say "    \`$SELF_CMD record launchDir <dir>\`)"
        ;;
      *)
        say "1. Where the launch copies go: \"$PF_VALUE\" is not an absolute path, so it"
        say "   would be recorded relative to wherever a later command happened to run."
        say "   NOT RECORDED. Taking the default instead: $rec"
        say "   (nothing is missing here and there is nothing to create: give the SAME"
        say "    directory as an ABSOLUTE path, one starting with \`/\`, then re-run"
        say "    \`$SELF_CMD preflight\` — or set it directly with"
        say "    \`$SELF_CMD record launchDir /absolute/dir\`)"
        ;;
    esac
  else
    say ""
    say "1. Where the launch copies go — WOULD HAVE ASKED. Proceeding with: $rec"
    say "   (a throwaway directory overwrites nothing, so taking the default is free;"
    say "    stopping the night over it would not be)"
  fi
  if pf_dir_usable "$rec"; then
    ap_set launchDir "$rec"
    pf_withdraw_say "$PF_Q_NO_LAUNCH_DIR" "withdrawn by preflight: launchDir is now $rec."
    return 0
  fi
  # THE DEFAULT ITSELF IS UNUSABLE. There is now nowhere on this machine to make
  # the throwaway worktree every live check runs from, which no default can
  # invent, so this one DOES stop — settleable and self-retiring like the rest.
  say "   And the default is not usable either: $rec"
  if pf_settled "$PF_Q_NO_LAUNCH_DIR"; then
    say "   SETTLED BY YOU [$PF_SETTLED_ID] — \"$PF_SETTLED\". Proceeding on your answer."
    return 0
  fi
  say "   STOPPING deliberately: a live check cannot run from a directory it cannot write."
  pf_stop "$PF_Q_NO_LAUNCH_DIR" \
    "every live check runs from a throwaway worktree and a throwaway HOME made under launchDir, and neither the answer given nor the ${TMPDIR:+TMPDIR }default ($rec) is a writable absolute path." \
    "mkdir -p <dir> && $SELF_CMD record launchDir <dir>   # then: $SELF_CMD preflight" \
    "nothing has run, so there is nothing to undo."
  return 0
}

# --- question 2: is a test command recorded --------------------------------
# PROCEEDS with nobody there, because LCARS ALREADY HAS a deliberate answer for
# a repo with no test system: `next` names `foundation`, which sets one up as
# the run's first step. The gap has a recorded route, so it does not need him
# awake — and the alternative (guess a command) is actively worse than the gap.
pf_q_test_command() {
  local tc
  tc="$(ap_j testCommand)"
  [ -n "$tc" ] || tc="$(jfile "$CFG" testCommand)"
  if [ -n "$tc" ]; then
    say ""
    say "2. The test command the push gate runs: already recorded ($tc) — not asking."
    return 0
  fi
  if pf_prompt "2. No test command is recorded, so the push gate has nothing to gate on. Type the suite command, or take the default." "$PF_TC_FOUNDATION"; then
    say ""
    if [ "$PF_VALUE" != "$PF_TC_FOUNDATION" ]; then
      ap_set testCommand "$PF_VALUE"
      say "2. The test command: recorded testCommand = $PF_VALUE"
    else
      say "2. The test command: left to the foundation step — nothing recorded."
    fi
    return 0
  fi
  say ""
  say "2. The test command — WOULD HAVE ASKED. Proceeding with: $PF_TC_FOUNDATION"
  say "   (nothing is recorded, deliberately: a guessed suite either refuses every"
  say "    push or passes vacuously and pushes red. \`next\` names the foundation"
  say "    step, which sets a real one up as this run's first piece of work)"
  return 0
}

# --- question 3: is there somewhere to push, and does it ANSWER -------------
# STOPS DELIBERATELY with nobody there. There is nothing honest to invent: with
# no remote nothing can be pushed and no pull request can be opened, so the run
# dies at the gate whatever happens next. Stopping at second zero costs a
# message; finding out at 03:00 costs the night — that is the fourth failure.
#
# AND IT SPEAKS TO THE OTHER END (fix 2). A `remote get-url` is a NAME CHECK: it
# proves a config line exists, which a deleted repo, a typo'd host and revoked
# auth all satisfy. See `pf_remote_reachable` for the measurement and for why
# the probe is bounded.
pf_q_somewhere_to_push() {
  local url noissue
  url="$("$GIT_BIN" -C "$CWD" remote get-url origin 2>/dev/null || true)"
  noissue="$(pf_missions_without_issue)"

  if [ -z "$url" ]; then
    # HIS ANSWER FIRST. A question he has already answered is settled; minting a
    # clone of it is the defect fix 4 closes.
    if pf_settled "$PF_Q_NOPUSH"; then
      say ""
      say "3. Somewhere to push: SETTLED BY YOU [$PF_SETTLED_ID] — \"$PF_SETTLED\""
      pf_apply_push_answer "$PF_SETTLED"
      return 0
    fi
    # `record localOnly true` IS A DECISION, NOT A NOTE (S300 fix2). Measured:
    # it was accepted silently — "recorded localOnly" — and then nothing read
    # it, so a repo with no remote kept stopping. It looked like it had worked
    # and did nothing, which is the worst of the three available behaviours.
    # `cmd_record` now maps it onto `push.mode`, and this is the read.
    if [ "$(ap_j push.mode)" = "local-only" ]; then
      say ""
      say "3. Somewhere to push: NOT ASKING — push.mode is recorded as local-only, so"
      say "   nothing is pushed and no pull request is opened, and a remote is not"
      say "   needed. (undo: \`$SELF_CMD record push.mode origin\`)"
      pf_withdraw_say "$PF_Q_NOPUSH" "withdrawn by preflight: the run is recorded as local-only, so there is nothing to push."
      return 0
    fi
    if pf_prompt "3. There is nowhere to push: this repo has no \`origin\` remote, so nothing can be pushed and no pull request can be opened. Paste a remote URL to add, or type \`local\` to accept a local-only run." ""; then
      say ""
      pf_apply_push_answer "$PF_VALUE"
      return 0
    fi
    say ""
    say "3. Somewhere to push — WOULD HAVE ASKED, and there is NOTHING to default to."
    say "   STOPPING deliberately. There is nowhere to push: no \`origin\` remote, so"
    say "   nothing can be pushed and no pull request can be opened. A run that finds"
    say "   this out at 03:00 loses the rest of the night, and no part of the run can"
    say "   detect it or recover from it."
    if [ -n "$noissue" ]; then
      say "   LCARS had already recorded it: $noissue has githubIssue: null in its own state.json."
    fi
    pf_stop "$PF_Q_NOPUSH" \
      "preflight stops on this instead of starting a run that cannot finish. There is nothing honest to default to, and a night that discovers it at the gate is a night lost with no way to ask." \
      "cd $CWD && $GIT_BIN remote add origin <url>   # then: $SELF_CMD preflight" \
      "nothing has run, so there is nothing to undo; the add itself reverses with \`cd $CWD && $GIT_BIN remote remove origin\`."
    return 0
  fi

  # A RECORDED LOCAL-ONLY RUN IS NOT OVERRULED BY A REMOTE BEING PRESENT
  # (S300 fix2). The old body wrote `push.mode = origin` unconditionally, which
  # silently undid `record localOnly true` in any repo that happened to have an
  # origin — and then probed a remote the run was never going to use.
  if [ "$(ap_j push.mode)" = "local-only" ]; then
    say ""
    say "3. Somewhere to push: origin -> $url exists, but this run is recorded as"
    say "   local-only, so it is neither used nor probed. Nothing is pushed and no"
    say "   pull request is opened. (undo: \`$SELF_CMD record push.mode origin\`)"
    pf_withdraw_say "$PF_Q_NOPUSH" "withdrawn by preflight: the run is recorded as local-only, so there is nothing to push."
    pf_withdraw_say "$PF_Q_UNREACHABLE" "withdrawn by preflight: the run is recorded as local-only, so the remote is not used."
    pf_withdraw_say "$PF_Q_SLOW_REMOTE" "withdrawn by preflight: the run is recorded as local-only, so the remote is not used."
    return 0
  fi
  say ""
  say "3. Somewhere to push: origin -> $url — not asking."
  ap_set push.mode origin
  ap_set push.remote "$url"
  # THE PREREQUISITE IS SATISFIED, so its question retires itself (fix 4).
  pf_withdraw_say "$PF_Q_NOPUSH" "withdrawn by preflight: origin is now $url, so there is somewhere to push."
  if [ -n "$noissue" ]; then
    # SURFACED AT THE GATE, from the record. A push will work; opening a PR
    # for this mission will not, and this is the line the 2026-10-15 run had
    # on disk and never read.
    say "   BUT LCARS ALREADY RECORDED a Mission it could not get a forge issue for:"
    say "     $noissue  (githubIssue: null in its own state.json)"
    say "   Pushing works; opening a pull request for that Mission will not until it has one."
  fi
  pf_check_reachable "$url"
  return 0
}

# pf_apply_push_answer <answer> — the ONE reader of an answer to question 3,
# whether he typed it just now or recorded it with `answered` days ago. Three
# outcomes, and none of them is "ask again".
pf_apply_push_answer() {
  local ans="$1" low
  low="$(printf '%s' "$ans" | tr 'A-Z' 'a-z')"
  # LOCAL-ONLY, in his words — `pf_answer_means_local_only` owns the list of
  # ways a man says "don't push", so this reader and the forge-login check
  # (S300 fix2) cannot disagree about what he meant.
  if pf_answer_means_local_only "$ans"; then
    ap_set push.mode local-only
    ap_set push.remote ""
    say "3. Somewhere to push: recorded push.mode = local-only — nothing will be"
    say "   pushed and no pull request opened. Your call, and it is on the record."
    pf_withdraw_say "$PF_Q_NOPUSH" "withdrawn by preflight: you chose a local-only run, so there is nothing left to answer."
    return 0
  fi
  case "$low" in
    *://*|*@*:*|/*|*.git)
      if "$GIT_BIN" -C "$CWD" remote add origin "$ans" 2>/dev/null; then
        ap_set push.mode origin
        ap_set push.remote "$ans"
        say "3. Somewhere to push: added origin -> $ans"
        say "   undo:  cd $CWD && $GIT_BIN remote remove origin"
        pf_withdraw_say "$PF_Q_NOPUSH" "withdrawn by preflight: origin was added as $ans."
        pf_check_reachable "$ans"
      else
        say "3. Somewhere to push: could NOT add origin -> $ans (git refused it)."
        say "   Add it by hand, then re-run \`$SELF_CMD preflight\`."
        PF_STOPS=$((PF_STOPS + 1))
      fi
      ;;
    *)
      # SOMETHING THAT IS NEITHER. Say so and stop — but raise NOTHING: either a
      # human is in the room right now, or this came from a question he has
      # already answered, and a clone of it in his inbox is the thing fix 4
      # exists to stop.
      say "3. Somewhere to push: \"$ans\" is neither a remote URL nor a local-only"
      say "   decision, so preflight cannot act on it. STOPPING, and raising nothing new."
      say "   Either:  cd $CWD && $GIT_BIN remote add origin <url>"
      say "   or:      $SELF_CMD answered ${PF_SETTLED_ID:-<id>} \"local-only\""
      PF_STOPS=$((PF_STOPS + 1))
      ;;
  esac
  return 0
}

# pf_check_reachable <url> — the reachability half of question 3.
# A FACT CHECK, SO IT NEVER PROMPTS. Nothing he could type into this process
# makes a dead host answer; the two real moves are a command (fix the URL) or a
# decision (`answered <id> "push anyway"`), and the second one is exactly what a
# recorded question is for. So this stops with a settleable question even when a
# human is present, and `PF_ASKED` is untouched.
pf_check_reachable() {
  local url="$1" rc
  pf_remote_reachable origin
  rc=$?
  case "$rc" in
    0|2)
      if [ "$rc" = 2 ]; then
        say "   reachable: git reached it; it has no refs yet (an empty remote — the first push fills it)."
      else
        say "   reachable: git reached it and read its refs. A name check would not have."
      fi
      pf_withdraw_say "$PF_Q_UNREACHABLE" "withdrawn by preflight: origin answers again ($url)."
      pf_withdraw_say "$PF_Q_SLOW_REMOTE" "withdrawn by preflight: origin answered inside the ${PROBE_TIMEOUT}s bound ($url)."
      return 0
      ;;
  esac
  # A DEADLINE AND A REFUSAL ARE TWO DIFFERENT FINDINGS (S300 fix1), so they are
  # two different questions with two different stories. The old code printed one
  # headline for both and put the only honest distinction — `rc 124` — in small
  # type under advice that contradicted it.
  local qkey qother
  if [ "$rc" = 124 ]; then
    qkey="$PF_Q_SLOW_REMOTE"; qother="$PF_Q_UNREACHABLE"
  else
    qkey="$PF_Q_UNREACHABLE"; qother="$PF_Q_SLOW_REMOTE"
  fi
  say ""
  if [ "$rc" = 124 ]; then
    say "3b. The remote did not answer IN TIME, which is NOT the same as not answering:"
    say "    the probe outran its ${PROBE_TIMEOUT}s bound (rc 124), so git never said no."
    say "    Nothing here is evidence against the URL or the auth."
  else
    say "3b. The remote does NOT answer: \`git ls-remote origin\` failed (rc $rc)."
  fi
  say "    $url"
  # HIS DECISION ABOUT THIS REMOTE COVERS BOTH READINGS. A remote that is slow
  # one night and refusing the next would otherwise put a second, near-identical
  # card in the inbox of a man who has already said what he wants done.
  if pf_settled "$qkey" || pf_settled "$qother"; then
    say "    SETTLED BY YOU [$PF_SETTLED_ID] — \"$PF_SETTLED\". Proceeding on your answer;"
    say "    nothing is re-asked and no new question is raised."
    return 0
  fi
  if [ "$rc" = 124 ]; then
    say "    IT MAY SIMPLY BE SLOW. A cold VPN handshake, a monorepo with a huge ref"
    say "    advertisement and a loaded forge all read exactly like this, and all three"
    say "    are healthy. Time it by hand: if \`git ls-remote origin\` answers at all,"
    say "    the remote is fine and this bound is just too short for it."
    say "    STOPPING deliberately — but on a QUESTION, not a diagnosis. And THIS stop"
    say "    cannot retire itself, because a slow remote stays slow: it will keep"
    say "    stopping here until you settle it or widen the bound."
    say "    Either:  $SELF_CMD answered <id> \"it's just slow\"   # clears it for good"
    say "    or:      LCARS_ECH_PROBE_TIMEOUT=60 $SELF_CMD preflight"
    pf_stop "$qkey" \
      "the probe hit its ${PROBE_TIMEOUT}s DEADLINE before origin answered (rc 124) — a deadline, not a refusal: git never said no. It may simply be slow (a cold VPN handshake, a monorepo's huge ref advertisement, a loaded forge) and be perfectly healthy; nothing here says the URL or the auth is wrong. Only you can tell slow from dead: $url" \
      "cd $CWD && $GIT_BIN ls-remote origin   # time it by hand: if it answers, it is just slow — then: $SELF_CMD answered <id> \"it's just slow\" (or run preflight with LCARS_ECH_PROBE_TIMEOUT=60)" \
      "nothing has run, so there is nothing to undo."
    return 0
  fi
  say "    STOPPING deliberately. A config line is not a reachable remote: a deleted"
  say "    repo, a typo'd host and revoked auth all leave it intact and die at the"
  say "    pull-request gate at 03:00, which is the fourth dead night exactly."
  pf_stop "$qkey" \
    "preflight probed it with a bounded \`git ls-remote\` (every credential prompt muzzled) and it did not answer: $url (rc $rc). The push and the pull request both need this." \
    "cd $CWD && $GIT_BIN ls-remote origin   # see what it says, then fix the URL or the auth; or: $SELF_CMD answered <id> \"push anyway\"" \
    "nothing has run, so there is nothing to undo."
  return 0
}

# --- question 4: the forge login a pull request needs ----------------------
# STOPS DELIBERATELY, and never prompts — a fact check, like 3b. No
# authenticated forge CLI means no pull request, whatever the run builds: the
# same class and the same cost as having no remote, and one command to check.
# Nothing he can type into THIS process logs him in.
pf_q_forge_login() {
  local url rc
  # ONE COMMAND SETTLES THE OFFLINE CASE (S300 fix2). `pf_local_only_recorded`
  # reads push.mode AND a settled push question in his own words, so "ship
  # local-only, no push" answered once clears this check too — it does not come
  # back as a second card about a pull request nobody is opening.
  if pf_local_only_recorded; then
    say ""
    say "4. The forge login a pull request needs: NOT CHECKED — this run is local-only"
    say "   ($PF_LOCAL_ONLY_WHY), so nothing is pushed and no"
    say "   pull request is opened. A login cannot be needed for one."
    pf_withdraw_say "$PF_Q_FORGE_LOGIN" "withdrawn by preflight: the run is local-only, so no pull request is opened and no login is needed."
    return 0
  fi
  url="$(ap_j push.remote)"
  if [ -n "$url" ] && ! pf_remote_is_forge "$url"; then
    say ""
    say "4. The forge login a pull request needs: not asking — origin is a local path"
    say "   ($url), which has no account to log in to."
    pf_withdraw_say "$PF_Q_FORGE_LOGIN" "withdrawn by preflight: origin is a local path, which has no forge account."
    return 0
  fi
  if ! command -v "$GH_BIN" >/dev/null 2>&1 && [ ! -x "$GH_BIN" ]; then
    say ""
    say "4. The forge login a pull request needs: the forge CLI \`$GH_BIN\` is not on PATH."
    if pf_settled "$PF_Q_FORGE_LOGIN"; then
      say "   SETTLED BY YOU [$PF_SETTLED_ID] — \"$PF_SETTLED\". Proceeding on your answer;"
      say "   nothing is re-asked and no new question is raised."
      return 0
    fi
    say "   STOPPING deliberately — no CLI, no pull request, and no way to ask at 03:00."
    pf_stop "$PF_Q_FORGE_LOGIN" \
      "the forge CLI ($GH_BIN) is not on PATH, so the run can build and push and still never open the pull request it exists to open." \
      "install the GitHub CLI, then: $GH_BIN auth login   # then: $SELF_CMD preflight" \
      "nothing has run, so there is nothing to undo."
    return 0
  fi
  pf_bounded "$PROBE_TIMEOUT" "$GH_BIN" auth status
  rc=$?
  if [ "$rc" = 0 ]; then
    say ""
    say "4. The forge login a pull request needs: \`$GH_BIN auth status\` says logged in — not asking."
    pf_withdraw_say "$PF_Q_FORGE_LOGIN" "withdrawn by preflight: $GH_BIN auth status now reports a logged-in account."
    return 0
  fi
  say ""
  if [ "$rc" = 124 ]; then
    say "4. The forge login a pull request needs: \`$GH_BIN auth status\` outran its ${PROBE_TIMEOUT}s bound."
  else
    say "4. The forge login a pull request needs: \`$GH_BIN auth status\` says NOT logged in (rc $rc)."
  fi
  if pf_settled "$PF_Q_FORGE_LOGIN"; then
    say "   SETTLED BY YOU [$PF_SETTLED_ID] — \"$PF_SETTLED\". Proceeding on your answer;"
    say "   nothing is re-asked and no new question is raised."
    return 0
  fi
  say "   STOPPING deliberately. No login, no pull request — the run would build all"
  say "   night and have nowhere to deliver it, and nothing inside it can log you in."
  pf_stop "$PF_Q_FORGE_LOGIN" \
    "preflight ran a bounded \`$GH_BIN auth status\` and it reported no usable login (rc $rc). Pushing may work; opening the pull request will not." \
    "$GH_BIN auth login   # then: $SELF_CMD preflight" \
    "nothing has run, so there is nothing to undo."
  return 0
}

# --- question 5: the engine's unattended permission ------------------------
# THE BIGGEST GAP OF THE FOUR DEAD NIGHTS, and the subject of this playbook's
# OPENING SECTION: with COPILOT_ALLOW_ALL unset, a measured EEH round was
# refused on every command — including read-only ones — with "Permission denied
# because no interactive user response was available", after four rounds had
# worked. From outside, that blocked run and a healthy idle one are identical,
# and nothing inside it can detect or recover from it. Three of the four nights
# are this one fact, and the preflight that exists to prevent them did not
# mention it.
#
# STOPS DELIBERATELY, and never prompts. There is nothing to default to and
# nothing he can type HERE that would help: the variable must be exported in the
# shell that LAUNCHES the run — this process's parent — and a child cannot set
# its parent's environment. So the honest move is to stop at second zero with
# the one command that fixes it. `answered <id> "…"` is his override, and it is
# consumed on the next run.
#
# ENGINE-AWARE: a copilot fact. A claude run is unaffected and says so.
# EXACTLY `true`: this playbook's own setup section is explicit that `1`, `yes`,
# `on` and `y` auto-approve TOOLS without trusting the working directory, so a
# truthy-but-wrong spelling is a FAILING value and is named as one. That is the
# hardest version of this to debug at 03:00 and the cheapest to catch here.
pf_q_engine_permission() {
  local eng val how
  eng="$(ap_j engine)"
  [ -n "$eng" ] || eng="$(jfile "$CFG" engine)"
  if [ "$eng" != "copilot" ]; then
    say ""
    say "5. The engine's unattended permission: not asking — engine is ${eng:-unset},"
    say "   and COPILOT_ALLOW_ALL is a copilot fact."
    pf_withdraw_say "$PF_Q_ALLOW_ALL" "withdrawn by preflight: the engine is ${eng:-unset}, so COPILOT_ALLOW_ALL does not apply."
    return 0
  fi
  val="${COPILOT_ALLOW_ALL-}"
  if [ "$val" = "true" ]; then
    say ""
    say "5. The engine's unattended permission: COPILOT_ALLOW_ALL=true is exported — not asking."
    pf_withdraw_say "$PF_Q_ALLOW_ALL" "withdrawn by preflight: COPILOT_ALLOW_ALL=true is exported in this environment."
    return 0
  fi
  say ""
  if [ -n "$val" ]; then
    say "5. The engine's unattended permission: COPILOT_ALLOW_ALL is set to \"$val\", which"
    say "   is NOT the string \`true\`. Other truthy spellings (1, yes, on, y) only"
    say "   auto-approve tools; they do not TRUST the working directory, so an"
    say "   unattended copilot run is still refused on every command."
  else
    say "5. The engine's unattended permission: COPILOT_ALLOW_ALL is not set, so an"
    say "   unattended copilot run is refused on every command — including read-only"
    say "   ones — with \"Permission denied because no interactive user response was"
    say "   available\". Nothing inside a blocked run can detect or recover from it."
  fi
  if pf_settled "$PF_Q_ALLOW_ALL"; then
    say "   SETTLED BY YOU [$PF_SETTLED_ID] — \"$PF_SETTLED\". Proceeding on your answer;"
    say "   nothing is re-asked and no new question is raised."
    return 0
  fi
  say "   STOPPING deliberately. This is what killed three of the four nights, and a"
  say "   child process cannot export a variable into the shell that launched it."
  if [ -n "$val" ]; then
    how="set to \"$val\" rather than the string true"
  else
    how="not set at all"
  fi
  pf_stop "$PF_Q_ALLOW_ALL" \
    "the engine is copilot and COPILOT_ALLOW_ALL is $how. An unattended copilot run is then refused on every command, with no interactive user to approve it and no way for the run to recover." \
    "export COPILOT_ALLOW_ALL=true   # in the shell you launch from, then: $SELF_CMD preflight" \
    "nothing has run, so there is nothing to undo; unset the variable to reverse it."
  return 0
}

# cmd_preflight — the one round. Exits 10 when something stopped it, which is
# this driver's existing "a question for the captain was recorded" code.
cmd_preflight() {
  require_state
  PF_TTY=0; PF_ASKED=0; PF_STOPS=0; PF_YES_TO_ALL=0
  # THE SECOND DEFENCE, AND IT IS CHEAP. With SIGTTIN ignored, a background job
  # that reads the terminal gets a FAILED read instead of being stopped dead in
  # state `T` — and a failed read already means "nobody is there" here. Set for
  # the round only, and reset after, so nothing else in the process inherits an
  # opinion about job control. (TTOU for the same reason on the write side,
  # which only bites when the terminal has TOSTOP set.)
  trap '' TTIN TTOU 2>/dev/null || true
  pf_tty_present && PF_TTY=1
  if [ "$PF_TTY" = 1 ]; then
    PF_BOLD="$(printf '\033[1m')"
    PF_NORM="$(printf '\033[0m')"
  else
    PF_BOLD=""
    PF_NORM=""
  fi

  say "preflight: the setup questions, asked NOW — once you have gone there is nobody to ask."
  if [ "$PF_TTY" = 1 ]; then
    say "  Answered once, compactly. Every question carries a RECOMMENDED default, so"
    say "  \"yes\" is a valid answer to the whole block."
  else
    # NAMES THE REASON IT FOUND, not one guess for every case. "there is no
    # /dev/tty to ask on" was printed even when stdin was merely redirected and
    # again for a background job that had a perfectly good /dev/tty.
    say "  NO TERMINAL TO ASK ON — $PF_NO_TTY_WHY, so nothing is"
    say "  asked and nothing is waited on. Each item below prints the question it"
    say "  WOULD have asked and the value it proceeds on, or stops on."
  fi

  pf_q_launch_dir
  pf_q_test_command
  pf_q_somewhere_to_push
  pf_q_forge_login
  pf_q_engine_permission

  trap - TTIN TTOU 2>/dev/null || true
  say ""
  if [ "$PF_STOPS" -gt 0 ]; then
    say "preflight: asked $PF_ASKED question(s); STOPPING — $PF_STOPS prerequisite(s) nobody can default."
    say "  Settle it with \`$SELF_CMD answered <id> \"<what you decided>\"\` — that answer is"
    say "  READ on the next run, so the same question is never raised twice — or fix the"
    say "  cause and re-run \`$SELF_CMD preflight\`, which retires the question itself."
    return 10
  fi
  say "preflight: asked $PF_ASKED question(s); proceeding."
  return 0
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
  Pass --force to overwrite it, or edit one key with \`$SELF_CMD record <key> <value>\`.
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
  say "  $SELF_CMD record liveTargets.host <host>"
  say "  $SELF_CMD record captainOnlySteps '[{\"what\":\"…\",\"instructions\":\"…\",\"neededBy\":\"…\",\"done\":false}]'"
  say "then follow $SKILLS_DIR/lcars-eeh/HOLOGRAM-COMMAND-MODE.md."
  say ""
  # THE SWEEP RUNS WHILE HE IS STILL HERE. `init` is the one moment a human is
  # reliably present, so the setup questions are asked here and not discovered
  # at the gate hours later. A deliberate stop propagates (exit 10): there is no
  # point naming the next step of a run that cannot finish.
  cmd_preflight || return $?
  cmd_next
}

# ==========================================================================
# record — the "record, don't infer" primitive the MODEL uses
# ==========================================================================
# cmd_record <dotted.key> [value]
#
# `localOnly` IS HONOURED, NOT JUST STORED (S300 fix2). MEASURED: `record
# localOnly true` printed "recorded localOnly" and then NOTHING read it — a
# repo with no remote kept stopping at question 3. An accepted key that does
# nothing is a footgun: it reads as success. It is now an ALIAS onto the one key
# preflight actually reads (`push.mode`), and it says so out loud, so the
# captain can see which record his word landed in.
cmd_record() {
  [ $# -ge 1 ] || die "record: <dotted.key> <value>"
  require_state
  case "$1" in
    localOnly|local-only|local_only|localonly)
      case "$(printf '%s' "${2-true}" | tr 'A-Z' 'a-z')" in
        true|yes|1|on|local-only|local)
          ap_set push.mode local-only || die "record: could not write push.mode"
          ap_set push.remote "" || die "record: could not write push.remote"
          say "recorded $1 -> push.mode = local-only (the key preflight reads)"
          say "  nothing will be pushed and no pull request opened; questions 3 and 4"
          say "  are skipped. undo: $SELF_CMD record push.mode origin"
          return 0
          ;;
        false|no|0|off)
          ap_set push.mode "" || die "record: could not write push.mode"
          say "recorded $1=false -> push.mode cleared (preflight will ask about pushing again)"
          return 0
          ;;
      esac
      die "record: $1 takes true or false (it maps onto push.mode), not \"${2-}\""
      ;;
  esac
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

  local scope; scope="$(ap_keys scope)"
  if [ -z "$scope" ]; then
    printf 'align\t-\t%s\n' "no scope is set — pass --scope to init, or record it"
    return 0
  fi

  local initialization="" d
  for d in "$MISSIONS"/*; do
    [ "$(jfile "$d/state.json" missionType)" = "initialization" ] || continue
    [ "$(jfile "$d/state.json" stage)" = "done" ] && continue
    initialization="$(basename "$d")"; break
  done
  local foundation
  foundation="$(TOPLEVEL="$CWD"; . "$SKILLS_DIR/lcars-init/lcars-common.sh"
    lcars_test_readiness "$CFG"; printf '%s' "$LCARS_TESTREADY_FOUNDATION")"
  case "$foundation:$initialization" in greenfield:|untested:)
    printf 'foundation\t-\t%s\n' "no test foundation yet — file the initialization mission"
    return 0 ;;
  esac

  local used; used="$(slots_in_use)"
  if [ "$used" -ge "$MAX_SLOTS" ]; then
    printf 'wait\t-\t%s\n' "$used/$MAX_SLOTS parallel slots in use — two missions at a time is the ceiling; wait for a waiter to fire"
    return 0
  fi

  local ms id stage any=0
  for ms in ${initialization:-$scope}; do
    id="$ms"
    [ "$ms" = "$initialization" ] || id="$(ap_j "missions.$ms.id")"
    if [ -z "$id" ]; then
      printf 'file\t%s\t%s\n' "$ms" "$ms is not filed yet — if its own spec/brief has screens, holodeck first; otherwise file directly"
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
    if [ "$stage" = "verify" ]; then
      printf 'verify-gate\t%s\t%s\n' "$id" "$ms reached the Verify gate — read Number One, then run the live check"
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
  if [ "$action" = "file" ]; then
    say "IF $arg has screens (judge its own spec/brief):"
    say "NEXT: holodeck $arg"
    say "PLAYBOOK: $(playbook_heading holodeck)"
    say "OTHERWISE:"
  fi
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
    # EXCEPT a RUN-WIDE PREREQUISITE, which parks everything (S300 fix1).
    # `--mission -` is how a question says it belongs to no milestone, and every
    # preflight stop is exactly that: nowhere to push, no login, no engine
    # permission. No other milestone works around a missing remote, and
    # HOLOGRAM-COMMAND-MODE.md says plainly not to drive a milestone past a preflight stop —
    # so printing `ALSO RUNNABLE: foundation` beside one was the driver
    # contradicting the playbook, in the one place a model reads for its next
    # move. § 9's rule is untouched: a question filed against a MILESTONE still
    # parks only that milestone.
    if open_questions | cut -f2 | grep -qx -- '-'; then
      say "NOTHING ELSE IS OFFERED: that question is a run-wide prerequisite, not one"
      say "  milestone's. Fix the cause (or answer it) and re-run \`$SELF_CMD preflight\`;"
      say "  do not drive a milestone past a preflight stop."
    elif [ -n "${r_action:-}" ]; then
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
  say "ECH — $CWD"
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
    say "    answer one with: $SELF_CMD answered <id> \"<what he said>\""
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
    die "drive: $m has already failed $prior drives in a row and the cap is $MAX_DRIVE_FAILURES — the captain has the question (\`$SELF_CMD status\`). Clear it with \`$SELF_CMD answered <id>\` or \`$SELF_CMD record drivers.$m.failures ''\` once the cause is fixed." 11
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
  say "  ask \`$SELF_CMD next\` / \`$SELF_CMD stalled\` rather than reading the log."
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
        "$m has failed $fails drives in a row (last exit $rc) and the ECH has stopped retrying it." \
        "Repeating a failure that never changes is an LCARS bug with no verb-level workaround — one of the four things that may reach you. A fourth attempt would spin until morning and achieve nothing." \
        "LCARS_GATE_TIMEOUT=$gt bash $RUN_SCRIPT drive --mission $m   # in the FOREGROUND; its last log is $log" \
        "nothing was merged and nothing to undo. Once the cause is fixed, \`$SELF_CMD answered <id>\` clears the counter and the mode resumes."
    fi
  fi
  ap_set "drivers.$m.driverPid" ""
  ap_set "drivers.$m.exitedAt" "$(now)"
  ap_set "drivers.$m.pid" ""
  # NO PING FOR A ROUTINE STOP. `notify … drive-stopped` used to fire on EVERY
  # drive exit, exit 0 included — three pings from three routine stage stops in
  # one tester run. HOLOGRAM-COMMAND-MODE.md § 9 promises exactly four things reach the
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
    printf '%s stalled mission(s). Run `%s next` for the step, then `%s record drivers.<id>.pickedUpAt %s`.\n' \
      "$n" "$SELF_CMD" "$SELF_CMD" "$(now)"
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
# one problem - the interrupt-budget violation HOLOGRAM-COMMAND-MODE.md section 9
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
      say "  record his answer with: $SELF_CMD answered ${qid#=} \"<what he said>\""
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
  say "  record his answer with: $SELF_CMD answered $qid \"<what he said>\""
}

# ==========================================================================
# ask — the ONE supported way for the MODEL to raise a question by hand
# ==========================================================================
# WHY A VERB AND NOT A FIELD. HOLOGRAM-COMMAND-MODE.md § 9 used to tell the model to write
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
  $SELF_CMD ask \"<what you need from him>\" --mission <id> [--why <why it is safe/needed>] [--command <the ONE command that would run>] [--rollback <how to undo it>]"
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
  out="$(LCARS_SELF_CMD="$SELF_CMD" "$PY" - "$APJSON" "$1" "${2-}" "$(now)" 2>&1 <<'PY'
import json, os, sys
f, want, answer, ts = sys.argv[1:5]
# The name the caller must TYPE, handed in by the shell (S277). A literal here
# would print `ech.sh status`, which is not a command on any PATH.
selfcmd = os.environ.get("LCARS_SELF_CMD") or "lcars-ech"
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
    sys.stderr.write("no OPEN question with id or mission '%s' — `%s status` lists them" % (want, selfcmd))
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
  # ONE COMMAND HAS TO READ LIKE ONE COMMAND (S300 fix2). "Still open: q2" is
  # true at this instant, and it sent a captain who had just said "ship
  # local-only, no push" off to answer a second question about a pull request
  # nobody is going to open. Preflight withdraws that one by itself now, so say
  # so here rather than leaving him to discover it.
  if pf_answer_means_local_only "${2-}" \
     && open_questions | grep -q 'forge CLI is not logged in'; then
    say "  (that makes this a local-only run, so the forge-login question closes itself"
    say "   on the next \`$SELF_CMD preflight\` — you do not owe it an answer.)"
  fi
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
      "bash $SKILLS_DIR/lcars-resolve-logs/resolve-logs.sh --parent $m   # then re-verify, then: $SELF_CMD land $m" \
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
      "bash $APPROVE_SCRIPT --mission $m --reapprove   # then: $SELF_CMD land $m" \
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
  # `worktree <mission>` resolves the branch from the ECH record;
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
    sys.stderr.write("lcars ech: ledger: not valid JSON (%s)\n" % e)
    sys.exit(1)
if not isinstance(d, dict):
    sys.stderr.write("lcars ech: ledger: the entry must be a JSON object\n")
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
# not inside Claude Code — a harness-only tool cannot be the ECH's
# heartbeat, because on their machine it does not exist. `crontab` is on every
# POSIX box, it survives the session dying, and the captain can read and delete
# the line himself. The mode owns exactly ONE line, tagged so `remove` can find
# it without touching anything else in his crontab.
HB_MARK="# LCARS-ECH"
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
      say "  it calls \`$SELF_CMD stalled\` and acts only when a pipeline ended with nobody picking it up."
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
# reads the same files. One source, two readers: the EEH follows the prose,
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
  # a second thing that can be subtly wrong and the EEH and the first officer
  # must check the same tree. It holds the branch already (from the mission's
  # own state.json, read by xo.sh) and has no autopilot.json, so it passes the
  # branch rather than asking this script to look the mission up.
  [ -n "$br" ] || br="$(mstate "$m" branch)"
  [ -n "$br" ] || die "worktree: mission $m has no branch in its state.json"
  # WHERE THE LAUNCH COPIES GO IS THE RECORDED ANSWER (preflight question 1),
  # not a re-derivation. ${TMPDIR:-/tmp} stays the fallback, so a caller with no
  # autopilot.json at all — xo-run.py reuses this helper — behaves exactly as
  # before.
  local base; base="$(ap_j launchDir)"
  [ -n "$base" ] || base="${TMPDIR:-/tmp}"
  base="${base%/}"
  mkdir -p "$base" 2>/dev/null || true
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
  say "A BUG:      $SELF file-bug --parent $m --prd <bug-prd.md>   (template: $SKILLS_DIR/lcars-eeh/bug-prd.md)"
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
  # evidence directory named there is nothing to look up in the ECH record
  # — so a mission (and autopilot.json) is not required for that call.
  if [ -z "$evdirarg" ]; then
    require_state
    mexists "$m" || die "workflow-run: no mission $m in $MISSIONS"
  fi
  [ -f "$wf" ] || die "workflow-run: no workflow file at $wf"
  wf="$(cd "$(dirname "$wf")" && pwd)/$(basename "$wf")"
  # The repo root is the one the workflow's own paths are relative to — the
  # directory holding .github/, not whatever cwd the EEH happens to be in.
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
  [ "$n" -gt 0 ] || die "file-bug: --prd <file> is required (once per bug). The template is $SKILLS_DIR/lcars-eeh/bug-prd.md."
  mexists "$parent" || die "file-bug: no parent mission $parent in $MISSIONS"
  [ -x "$LOG_SCRIPT" ] || [ -f "$LOG_SCRIPT" ] || die "file-bug: no lcars log at $LOG_SCRIPT"

  # VALIDATE EVERY PRD FIRST, so a bad second PRD does not leave a filed first.
  local i p msg
  i=0
  while [ "$i" -lt "$n" ]; do
    p="${PRDS[$i]}"
    [ -f "$p" ] || die "file-bug: no PRD at $p"
    if ! msg="$(bug_prd_problems "$p")"; then
      printf 'lcars ech: file-bug: %s is not an evidence-first bug PRD.\n' "$p" >&2
      printf '%s\n' "$msg" >&2
      printf 'Nothing was filed. The template is %s/lcars-eeh/bug-prd.md.\n' "$SKILLS_DIR" >&2
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
# EEH'S CALL: this prints the recommendation and the commands; the EEH
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
  say "  THE MERGE IS THE ECH'S CALL — this is the recommendation, and every"
  say "  override is recorded in the overrides ledger with its evidence path."
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
<title>ECH progress</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; max-width: 60rem; }
  table { border-collapse: collapse; width: 100%%; }
  td, th { border-bottom: 1px solid #ddd; padding: .4rem .6rem; text-align: left; }
  .pass { color: #0a7a2f; } .bugs { color: #c0392b; } .none { color: #888; }
  ul { padding-left: 1.2rem; }
  @media (max-width: 500px) { body { margin: .75rem; } }
</style></head>
<body>
<h1 id="report-title">ECH progress</h1>
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
# exec — run a SIBLING skill's script, resolved from THIS clone (S277)
# ==========================================================================
# WHY THIS EXISTS. HOLOGRAM-COMMAND-MODE.md names four scripts that belong to other skills
# (lcars-init/establish-vision.sh, lcars-file/file.sh,
# lcars-resolve-logs/resolve-logs.sh, lcars-respond/respond.sh). It used to name
# them as `bash ~/.claude/skills/<skill>/<script>`, which is Claude Code's
# install mount: on a Copilot-only machine that path does not exist, and the
# S277 spike watched a real model run such a line, take exit 127 and STOP.
#
# Those four are not `lcars` verbs — `lcars file` runs an Align CONVERSATION and
# `lcars.sh` has no `file`/`respond`/`establish-vision` route at all — so routing
# them through an `lcars` launcher would have meant adding dispatch to another
# skill's front door and still not reaching `file.sh --prd`. Instead the driver
# the playbook already uses on every line exposes them, resolved relative to its
# OWN physical location ($SKILLS_DIR), which is correct under either mount:
#
#   lcars-ech exec lcars-file/file.sh --prd <path> --engine copilot
#   lcars-ech exec lcars-file file.sh  --prd <path> --engine copilot
#
# It adds NO stage logic: it resolves a path and hands over with `exec`.
cmd_exec() {
  local spec="${1:-}" script=""
  [ -n "$spec" ] || die "exec: name a skill script, e.g. \`exec lcars-file/file.sh --prd <path>\`"
  shift
  case "$spec" in
    */*) script="$spec" ;;
    *)   # two-argument form: <skill> <script>
         [ -n "${1:-}" ] || die "exec: $spec — name the script too, e.g. \`exec $spec <script>.sh\`"
         script="$spec/$1"; shift ;;
  esac
  case "$script" in
    *..*|/*) die "exec: refusing an out-of-tree path: $script" ;;
  esac
  local target="$SKILLS_DIR/$script"
  [ -f "$target" ] || die "exec: no such script in this LCARS clone: $target"
  exec bash "$target" "$@"
}

# ==========================================================================
# the announcement
# ==========================================================================
# THE ECH SAYS WHO IT IS — WITHOUT EVER TOUCHING THE DATA PATH.
#
# This program is the Emergency Command Hologram, and it says so. But it is also
# the thing the chain, xo-run.py and the suites call dozens of times a run and
# PARSE. Its verbs emit line-oriented machine records on STDOUT: `playbook`
# prints a bare TAB-SEPARATED table with no prefix at all, `next` prints
# `NEXT:`/`WHY:`/`PLAYBOOK:` lines asserted with a `^` anchor, and `worktree`
# prints `WORKTREE:`/`HOME:` lines that xo-run.py scans by prefix — reporting a
# refusal by reading the LAST line of the output. A banner anywhere on stdout is
# therefore indistinguishable from data: at the top it corrupts a first-line
# reader, at the bottom it corrupts xo-run.py's error path. There is no safe
# position on stdout, so the banner is not on stdout.
#
# It goes to STDERR, and only when stdout is a REAL TTY — i.e. a human is
# looking. Command substitution, a pipe and subprocess capture_output are all
# not a tty, so every captured call is silent and stdout stays BYTE-IDENTICAL
# to before the rename. `LCARS_ECH_QUIET=1` is the explicit off switch for a
# human who is in a loop and tired of reading it.
#
# It is a VALUE check, not a presence check, and deliberately: `=0` has to mean
# "not quiet". A `-z` test silences the banner for ANY non-empty value, so
# somebody writing `LCARS_ECH_QUIET=0` to say "leave it on" would get the
# opposite of what they asked for. `[ "${X:-0}" != "1" ]` is the same idiom
# `LCARS_BASE_QUIET` and every other boolean switch in this repo already uses.
#
# NOT "ONCE PER SESSION", DELIBERATELY. Each `lcars-ech <verb>` is its own
# short-lived process, so "only the first time this session" would need new
# persisted state in autopilot.json — new behaviour, which a rename may not add.
# The tty test needs no state and costs nothing.
if [ -t 1 ] && [ "${LCARS_ECH_QUIET:-0}" != "1" ]; then
  printf '%s\n' "LCARS ECH — the Emergency Command Hologram. Please state the nature of the command emergency." >&2
fi

# ==========================================================================
# dispatch
# ==========================================================================
SUB="${1:-}"
[ $# -gt 0 ] && shift
case "$SUB" in
  init)        cmd_init "$@" ;;
  preflight)   cmd_preflight "$@" ;;
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
  exec)        cmd_exec "$@" ;;
  ''|-h|--help|help) usage ;;
  *)           printf 'lcars ech: unknown subcommand %s\n' "$SUB" >&2; usage ;;
esac
