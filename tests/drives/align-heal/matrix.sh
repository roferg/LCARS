#!/usr/bin/env bash
# Prove Align end-to-end, live worker, driven to FILED — and, in the two
# `capstone` modes, on through Research → … → Schedule → Implement → the VERIFY
# gate, where the stand-in approves and the (faked) PR merges.
#
#   bash matrix.sh <label> <holo|plain|capstone|capstone-plain> [--dry-run]
#
# LCARS_DRIVE_REPO=<checkout>       which LCARS source is under test
# LCARS_DRIVE_ENGINE=copilot|claude WHICH CLI runs the grill AND the pipeline
#                                   (default copilot — an existing invocation is
#                                   byte-identical). The STAND-IN matcher is
#                                   always copilot: it is free, and it is not the
#                                   thing under test.
# LCARS_DRIVE_TARGET_SRC=<repo>     clone THIS repo as the mission target
#                                   (default: an empty throwaway git repo, which
#                                   is fine for Align but gives Research/Plan
#                                   nothing real to read — point it at the real
#                                   product repo for a meaningful capstone)
set -u
SD="$(cd "$(dirname "$0")" && pwd)"                 # this rig
SP="$(cd "$SD/.." && pwd)"                          # tests/drives
REPO="${LCARS_DRIVE_REPO:-/Users/roganferguson/Projects/LCARS}"
LABEL="${1:?label}"; MODE="${2:?holo|plain|capstone|capstone-plain}"
DRYRUN=0
case "${3:-}" in
  --dry-run) DRYRUN=1 ;;
  '') : ;;
  *) echo "unknown argument: $3" >&2; exit 2 ;;
esac
[ "${LCARS_DRIVE_DRYRUN:-0}" = "1" ] && DRYRUN=1

case "$MODE" in
  holo|plain|capstone|capstone-plain) : ;;
  *) echo "unknown mode '$MODE' — want holo|plain|capstone|capstone-plain" >&2; exit 2 ;;
esac
# The two lanes, and whether the pipeline runs after FILED. `capstone` keeps its
# old meaning EXACTLY (the holo lane + the pipeline) so old invocations don't move.
case "$MODE" in
  holo)           LANE=holo;  PIPELINE=0 ;;
  plain)          LANE=plain; PIPELINE=0 ;;
  capstone)       LANE=holo;  PIPELINE=1 ;;
  capstone-plain) LANE=plain; PIPELINE=1 ;;
esac

# ── THE ENGINE KNOB ─────────────────────────────────────────────────────────
# One cell = one engine, end to end: the Align grill the daemon runs AND the
# cold pipeline workers. They are never split (captain's standing constraint:
# each engine is a complete independent path).
ENGINE="${LCARS_DRIVE_ENGINE:-copilot}"
case "$ENGINE" in
  copilot|claude) : ;;
  *) echo "LCARS_DRIVE_ENGINE must be copilot or claude (got '$ENGINE')" >&2; exit 2 ;;
esac

SRC="${LCARS_DRIVE_RECORD_DIR:-$HOME/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260829-002}"
OUT="$SD/runs/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
TARGET="$OUT/target"
ORIGIN="$OUT/origin.git"

# ── the mission target ──────────────────────────────────────────────────────
# A local clone (no network) when one is named, so Research/Plan/Implement have
# real code to read; otherwise the empty throwaway the Align lane only needs.
if [ -n "${LCARS_DRIVE_TARGET_SRC:-}" ]; then
  echo "cloning $LCARS_DRIVE_TARGET_SRC → $TARGET (local, no network)…"
  git clone -q --local --no-hardlinks "$LCARS_DRIVE_TARGET_SRC" "$TARGET" \
    || { echo "clone FAILED"; exit 1; }
  # SEED node_modules INTO THE CLONE. The fixture's own worktreeSetupCommand
  # symlinks deps per-package FROM THE CLONE ROOT ($MAIN) into each Implement
  # worktree — so a bare clone sends it down the `npm ci` branch, which needs the
  # NETWORK and would fail (or crawl) on an offline overnight drive, and every
  # cell would die at Implement for a reason that has nothing to do with what we
  # are testing. This is the wave-isolation lesson: a fixture must carry what a
  # real repo carries.
  if [ -d "$LCARS_DRIVE_TARGET_SRC/node_modules" ] && [ ! -e "$TARGET/node_modules" ]; then
    ln -snf "$LCARS_DRIVE_TARGET_SRC/node_modules" "$TARGET/node_modules"
    echo "  seeded node_modules -> $LCARS_DRIVE_TARGET_SRC/node_modules"
  fi
  mkdir -p "$TARGET/.git/lcars/missions"
  if [ -f "$LCARS_DRIVE_TARGET_SRC/.git/lcars/config.json" ]; then
    cp "$LCARS_DRIVE_TARGET_SRC/.git/lcars/config.json" "$TARGET/.git/lcars/config.json"
  else
    printf '{"testCommand":"true"}\n' > "$TARGET/.git/lcars/config.json"
  fi
else
  mkdir -p "$TARGET"
  ( cd "$TARGET" && git init -q . && git config user.email t@t && git config user.name t \
    && echo "# t" > README.md && git add -A && git commit -qm init \
    && mkdir -p .git/lcars/missions && printf '{"testCommand":"true"}\n' > .git/lcars/config.json )
fi

# ── a THROWAWAY origin, always ──────────────────────────────────────────────
# `git clone --local` points origin at the captain's REAL repo, and Verify's
# PR-open does `git push -u origin <mission branch>`. That would write a mission
# branch into his working repo. Re-point origin at a bare repo inside this run's
# own dir: the push is real (so the PR-open path is genuinely exercised) but it
# lands in the run directory and dies with it. No network, no captain's repo.
git init -q --bare "$ORIGIN" || { echo "could not init $ORIGIN"; exit 1; }
(
  cd "$TARGET" || exit 1
  git remote remove origin >/dev/null 2>&1
  git remote add origin "$ORIGIN"
  # `main` is what the mission's state.json records as its base. Make sure it
  # exists both locally (rev-list main..branch) and on the origin (fetch main).
  git show-ref --verify --quiet refs/heads/main || git branch main HEAD 2>/dev/null
  git push -q origin "HEAD:refs/heads/main" 2>/dev/null
  cur="$(git symbolic-ref --short HEAD 2>/dev/null)"
  [ -n "$cur" ] && [ "$cur" != main ] && git push -q origin "HEAD:refs/heads/$cur" 2>/dev/null
  exit 0
)

MID=""
if [ "$LANE" = plain ]; then
  # $LCARS_DRIVE_IDEA overrides the plain lane's idea file. The default
  # `plain-idea.md` is a docs-site idea and does NOT fit every target repo — pair
  # it with the wrong target and Align correctly refuses to proceed, which reads
  # like a harness failure and is not one (MEASURED 2026-09-01: claude held the
  # gate asking which repo the Mission was for; copilot did not notice and
  # carried on, which is the worse of the two).
  IDEA="${LCARS_DRIVE_IDEA:-$SD/plain-idea.md}"
else
  # THE CAPTAIN'S ACTUAL LANE: a PARKED mission whose attachments live on disk,
  # aligned in place. file.sh --complete re-lists them, so the gate sees the
  # concept doc. (Passing them to /api/align/start does NOT work: that endpoint
  # takes `images`, not `attachments`, and an unknown key is silently ignored.)
  MID="lcars-20260829-002"
  MD="$TARGET/.git/lcars/missions/$MID"; rm -rf "$MD"; mkdir -p "$MD/attachments"
  cp "$SRC/attachments/attachment-01.html" "$SRC/attachments/attachment-02.md" "$MD/attachments/"
  cp "$SRC/attachments/attachment-02.md" "$OUT/"
  cp "$SRC/idea.md" "$MD/idea.md"
  # THE MONEY BUG: a PERSISTED workerBin has been measured beating the env var
  # (the daemon reads state.json.workerBin and feeds it back in as
  # $LCARS_WORKER_BIN, so "env last" does not save you). The parked mission's
  # pin must therefore BE the cell's engine, not a hardcoded one.
  printf '{"id":"%s","title":"MBR Builder","stage":"align","prdPending":true,"model":"claude-sonnet","workerBin":"%s","attachments":["attachments/attachment-01.html","attachments/attachment-02.md"],"githubIssue":177,"branch":"lcars/%s","base":"main"}\n' "$MID" "$ENGINE" "$MID" > "$MD/state.json"
  IDEA="$SRC/idea.md"
fi

# ── the claude fence, in whichever direction this cell needs ────────────────
# copilot cell: the blockshim REFUSES every claude spawn and the readout asserts
#               the count is 0 (a claude spawn is the defect).
# claude cell:  the countshim LOGS every claude spawn in the same format and
#               EXECS the real binary — the same count line now asserts NON-zero
#               (a claude spawn is the point).
export LCARS_BLOCK_LOG="$OUT/claude-attempts.log"
if [ "$ENGINE" = claude ]; then
  # Resolve the REAL claude BEFORE the shim dir goes on PATH, or the shim finds
  # itself. `command -v claude` alone is NOT safe here: if any editor ever
  # ships a claude shim the same way VS Code ships one for copilot, a plain
  # PATH search would hand the countshim the shim instead of the real binary,
  # and the exec below would recurse (see tests/drives/lib/real-worker.sh for
  # the fork-bomb this caused with copilot on 2026-09-15). Exported for the
  # shim to exec.
  # shellcheck source=/dev/null
  . "$SP/lib/real-worker.sh"
  LCARS_REAL_CLAUDE="$(lcars_resolve_real_worker claude "${LCARS_REAL_CLAUDE:-}")" || {
    echo "FATAL: no real claude binary found for the claude cell" >&2; exit 77; }
  export LCARS_REAL_CLAUDE
  SHIM="$SD/countshim"; SHIM_KIND="countshim (logs + execs the real claude)"
  CLAUDE_EXPECT="non-zero"
else
  SHIM="$SP/undrawn/blockshim"; SHIM_KIND="blockshim (refuses every claude spawn)"
  CLAUDE_EXPECT="0"
fi
export PATH="$SHIM:$PATH"
export LCARS_WORKER_BIN="$ENGINE" LCARS_GH_BIN="$SD/fake-gh"
export LCARS_FAKE_GH_STATE="$OUT/fake-gh-pr.state"
# PIN EVERY SKILL TO THE SAME CHECKOUT AS THE DAEMON. Without this the
# daemon resolves file.sh from ~/.claude/skills (a symlink to the MAIN
# checkout), so a "pristine" baseline silently ran the FIXED file.sh.
export LCARS_FILE_SCRIPT="$REPO/skills/lcars-file/file.sh"
export LCARS_RUN_SCRIPT="$REPO/skills/lcars-run/run.sh"
export LCARS_VERSION_CHECK_BIN="$REPO/skills/lcars-version/check.sh"
export LCARS_RESPOND_SCRIPT="$REPO/skills/lcars-respond/respond.sh"
export LCARS_APPROVE_SCRIPT="$REPO/skills/lcars-approve/approve.sh"
export LCARS_DRIVE_ENGINE="$ENGINE"

# ── VERIFY THE PIN BITES, before anything is trusted ────────────────────────
# Trap 1 in the README. A missing pinned script is fatal; a pin that resolves to
# a DIFFERENT checkout than ~/.claude/skills is exactly what we want, and is
# printed so a baseline can never be silently run against the fixed source.
pin_check() {
  local bad=0 k p installed
  echo "=== SKILL PINS (trap 1: every skill must come from THIS checkout) ==="
  for k in LCARS_FILE_SCRIPT LCARS_RUN_SCRIPT LCARS_VERSION_CHECK_BIN \
           LCARS_RESPOND_SCRIPT LCARS_APPROVE_SCRIPT; do
    eval "p=\"\$$k\""
    if [ -f "$p" ]; then printf '  %-26s %s\n' "$k" "$p"
    else printf '  %-26s %s   ** MISSING **\n' "$k" "$p"; bad=1; fi
  done
  installed="$HOME/.claude/skills/lcars-run/run.sh"
  if [ -f "$installed" ]; then
    local a b
    a="$(shasum "$LCARS_RUN_SCRIPT" 2>/dev/null | awk '{print $1}')"
    b="$(shasum "$installed" 2>/dev/null | awk '{print $1}')"
    printf '  pinned run.sh sha        %s\n' "${a:-?}"
    printf '  ~/.claude run.sh sha     %s   → %s\n' "${b:-?}" \
      "$( [ "$a" = "$b" ] && echo 'SAME checkout (pin is inert here)' || echo 'DIFFERENT checkout — the pin BITES' )"
  else
    printf '  ~/.claude/skills/lcars-run/run.sh  (not installed — nothing to shadow)\n'
  fi
  return $bad
}
pin_check || { echo "PIN CHECK FAILED — refusing to run."; exit 1; }

echo "=== CELL ==="
echo "  label      : $LABEL"
echo "  mode       : $MODE   (lane=$LANE, pipeline=$PIPELINE)"
echo "  ENGINE     : $ENGINE   (grill + cold pipeline workers)"
echo "  stand-in   : ${LCARS_STANDIN_BIN:-copilot} / ${LCARS_STANDIN_MODEL:-claude-sonnet-4.6}  (never the cell's engine — free, and not under test)"
echo "  claude shim: $SHIM_KIND"
echo "  claude spawns must be: $CLAUDE_EXPECT"
echo "  target     : $TARGET"
echo "  origin     : $ORIGIN   (throwaway bare — the captain's repo is never pushed to)"
echo "  record     : $SRC"
[ -n "$MID" ] && echo "  parked mission workerBin: $(sed -n 's/.*"workerBin"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TARGET/.git/lcars/missions/$MID/state.json")"
# THE PLAIN LANE HAS NO RECORD OF ITS OWN. `plain-idea.md` is a hand-typed idea
# about a docs-site strip; the default record is the MBR-Builder mission. The
# stand-in can only POINT at a decision the captain already made, so pairing them
# makes every turn a NO-MATCH BY CONSTRUCTION — the run fails at Align and the
# pipeline never spends. Say so loudly rather than letting a 30-minute drive
# discover it.
# Compare the IDEA ACTUALLY BEING DRIVEN against the record's own idea, byte for
# byte. The first version of this check hardcoded the phrase "recently viewed",
# so it went on firing after $LCARS_DRIVE_IDEA pointed the lane at a different
# idea entirely — a warning that cries wolf on every correct run is worse than no
# warning, because it trains you to scroll past the one that matters.
if [ "$LANE" = plain ] && ! cmp -s "$IDEA" "$SRC/idea.md" 2>/dev/null; then
  echo
  echo "  ⚠ THE PLAIN LANE AND THIS RECORD DO NOT MATCH."
  echo "    $IDEA is a different subject from $SRC/idea.md, and the"
  echo "    stand-in may only POINT at a decision already on the record — so every"
  echo "    turn will be NO-MATCH and the run will fail at Align."
  [ "$PIPELINE" = 1 ] && echo "    Point LCARS_DRIVE_RECORD_DIR at a mission whose idea.md IS this idea."
  echo
fi

# MATCHER PREFLIGHT — one call, before the daemon, before any spend.
# A matcher that cannot answer is indistinguishable in the turn log from a
# stand-in that finds nothing on the record: both read "no parseable JSON" and
# the drive reports "FAILED at Align" as though the RECORD were wrong. That
# happened for real on 2026-09-01, when copilot rotated `claude-sonnet-4.5` out
# from under us mid-session and 30 turns died silently. One call up front turns
# a wasted drive and a wrong conclusion into a one-line abort.
#
# IT MUST SIT OUTSIDE THE DRY-RUN BRANCH. The first version of this block was
# pasted INSIDE `if [ "$DRYRUN" = 1 ]` while itself testing for NOT-dry-run, so
# it was unreachable in both modes — dead code that read like a safeguard. It was
# caught only because the abort was actually exercised against a known-bad model
# and did not fire.
if [ "$DRYRUN" != 1 ]; then
  if ! PF="$(python3 "$SD/standin.py" preflight 2>&1)"; then
    echo
    echo "  ! $PF"
    echo "    The stand-in cannot answer anything, so this drive would fail at Align"
    echo "    for a reason that has NOTHING to do with the harness under test."
    echo "    Set LCARS_STANDIN_MODEL to a model \`copilot --model\` accepts."
    exit 3
  fi
  echo "  $PF"
fi

if [ "$DRYRUN" = 1 ]; then
  echo
echo "=== DRY RUN — no daemon, no grill, no worker, no spend ==="
  echo "  would start : python3 -m lcars_serve  (cwd $REPO/web)"
  echo "  would drive : python3 $SD/drive.py <port> $IDEA $OUT '${MID:-<filed-id>}' $SRC"
  [ "$PIPELINE" = 1 ] && \
  echo "  would then  : python3 $SD/capstone.py $TARGET '${MID:-<filed-id>}' $OUT $REPO $SRC"
  echo "  free plumbing proofs:  bash $SD/capstone-smoke.sh   ·   python3 $SD/standin.py smoke"
  exit 0
fi

export LCARS_SERVE_HOST=127.0.0.1 LCARS_SERVE_ADAPTER=local LCARS_SERVE_REPO_ROOT="$TARGET"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
export LCARS_SERVE_PORT="$PORT"
( cd "$REPO/web" && python3 -m lcars_serve >"$OUT/daemon.log" 2>&1 ) & DPID=$!
# ONLY the PID this script started. NEVER pkill/killall by name — the captain
# runs his own viewscreen daemon in parallel sessions.
trap 'kill -9 $DPID 2>/dev/null' EXIT
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/board" >/dev/null 2>&1 && break; python3 -c 'import time;time.sleep(0.5)'; done
curl -sf "http://127.0.0.1:$PORT/api/board" >/dev/null || { echo "DAEMON DOWN"; tail -20 "$OUT/daemon.log"; exit 1; }

# ── ALIGN: the stand-in answers ONLY from the captain's record ──────────────
python3 "$SD/drive.py" "$PORT" "$IDEA" "$OUT" "$MID" "$SRC"; ALIGN_RC=$?

echo "=== FILED? ==="
curl -s "http://127.0.0.1:$PORT/api/board" | python3 -c "
import sys,json
d=json.load(sys.stdin); tot=0
for st,cards in d['columns'].items():
    for c in cards:
        tot+=1; print('  ', c['id'], 'stage=',c['stage'], 'prdPending=', c.get('prdPending'))
print('   MISSIONS ON BOARD:', tot)
"
echo "=== leftovers ==="
find "$TARGET/.git/lcars" -name "prd-draft*" 2>/dev/null | sed 's/^/  DRAFT: /'
find "$TARGET/.git/lcars/tmp" -name "lcars-prd-*" 2>/dev/null | sed 's/^/  TMP: /'
ls "$TARGET/.git/lcars/missions"/*/prd.md 2>/dev/null | sed 's/^/  prd.md: /'
if [ "$LANE" != plain ]; then
  echo "=== questions carried ==="
  bash -c ". $REPO/skills/lcars-init/lcars-common.sh
    P=\$(ls $TARGET/.git/lcars/missions/*/prd.md 2>/dev/null | head -1)
    [ -n \"\$P\" ] || P=$OUT/prd.md
    want=\$(lcars_concept_open_questions $OUT/attachment-02.md | wc -l | tr -d ' ')
    if lcars_prd_questions_gate \"\$P\" $OUT/attachment-02.md 2>$OUT/gate.txt; then
      echo \"  GATE PASS — all \$want carried\"
    else
      echo \"  GATE REFUSED — dropped \$(grep -c '^  - ' $OUT/gate.txt) of \$want\"
    fi"
fi
echo "=== heals: $(grep -ci 'heal' "$OUT/daemon.log" 2>/dev/null || echo 0) · claude spawns: $( [ -f "$OUT/claude-attempts.log" ] && grep -c '^TIME:' "$OUT/claude-attempts.log" || echo 0 ) ==="

# The plain lane files a BRAND-NEW mission, so its id is only knowable now.
if [ -z "$MID" ]; then
  MID="$(ls -1t "$TARGET/.git/lcars/missions" 2>/dev/null | head -1)"
  [ -n "$MID" ] && echo "=== filed mission: $MID ==="
fi

[ "$PIPELINE" = 1 ] || exit $ALIGN_RC

# ── CAPSTONE: on through Research → … → Implement → the Verify gate ─────────
# A failed Align is NOT driven further: the expensive stages would be reading a
# PRD assembled around answers the captain never gave.
if [ "$ALIGN_RC" -ne 0 ]; then
  echo
  echo "############################################################"
  echo "# ALIGN FAILED — not spending on the pipeline."
  echo "# See $OUT/standin-log.txt and $OUT/result.json"
  echo "############################################################"
fi

if [ "$ALIGN_RC" -eq 0 ] && [ -n "$MID" ]; then
  echo; echo "=== POST-ALIGN DRIVE ==="
  python3 "$SD/capstone.py" "$TARGET" "$MID" "$OUT" "$REPO" "$SRC"
elif [ "$ALIGN_RC" -eq 0 ]; then
  echo "!! Align reported done but no mission dir was found under $TARGET/.git/lcars/missions"
fi

# ── the readout ─────────────────────────────────────────────────────────────
CLAUDE_SPAWNS=$( [ -f "$OUT/claude-attempts.log" ] && grep -c '^TIME:' "$OUT/claude-attempts.log" || echo 0 )
PERSISTED_BIN="$(sed -n 's/.*"workerBin"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TARGET/.git/lcars/missions/$MID/state.json" 2>/dev/null | head -1)"
USAGE="$( cd "$TARGET" && bash "$REPO/skills/lcars-run/run.sh" usage --mission "$MID" 2>/dev/null | tail -20 )"
OUT="$OUT" MID="$MID" BLOCKED="$CLAUDE_SPAWNS" USAGE="$USAGE" \
ENGINE="$ENGINE" CLAUDE_EXPECT="$CLAUDE_EXPECT" SHIM_KIND="$SHIM_KIND" \
PERSISTED_BIN="$PERSISTED_BIN" MODE="$MODE" python3 - <<'PY'
import json, os
out = os.environ["OUT"]
def load(n):
    try: return json.load(open(os.path.join(out, n)))
    except Exception: return {}
a, c = load("result.json"), load("capstone.json")
ac = a.get("counts", {})
human = a.get("humanAnswersRequired", 0) + c.get("humanAnswersRequired", 0)
bar = "=" * 62
# THE HEADLINE MUST NEVER READ 0 FROM AN ABSENT FILE. A drive that died before
# the first turn leaves no result.json, and a naive .get(…, 0) turns that into
# the very "zero human answers" the capstone is trying to earn.
if not a:
    verdict = "NO RESULT — the Align drive produced no result.json; nothing was measured"
    headline = "n/a  (NOTHING RAN)"
elif a.get("status") != "done":
    verdict = "FAILED at Align — status=%s" % a.get("status")
    headline = "%d (of %d turns)" % (human, ac.get("turns", 0))
elif human:
    verdict = "FAILED — the harness asked for %d thing(s) the captain never answered" % human
    headline = "%d" % human
elif not c:
    verdict = "ALIGN CLEAN — post-Align drive did not run"
    headline = "%d" % human
elif c.get("verifyApproved"):
    verdict = ("PASS through VERIFY — approved at the gate, PR merged (faked); "
               "zero human answers")
    headline = "%d" % human
else:
    verdict = ("STOPPED at %s WITHOUT the Verify approve — %s"
               % (c.get("stageReached"), c.get("stopped") or "?"))
    headline = "%d" % human
print("\n" + bar + "\nCAPSTONE READOUT — " + os.environ["MID"] + "\n" + bar)
print("  VERDICT                : %s" % verdict)
print("  cell                   : mode=%s  ENGINE=%s" % (os.environ["MODE"], os.environ["ENGINE"]))
print("  stage reached          : %s" % (c.get("stageReached") or a.get("status") or "?"))
print("  HUMAN ANSWERS REQUIRED : %s      <-- the headline; must be 0" % headline)
print("  align turns            : %d  (%d from a recorded decision, %d from a "
      "verified quote, %d closing)"
      % (ac.get("turns", 0), ac.get("recorded", 0), ac.get("quoted", 0), ac.get("closing", 0)))
print("  align healed           : %s" % a.get("healed"))
print("  driver rounds          : %s" % c.get("rounds"))
print("  Verify approve         : %s" % (c.get("verifyApprove") or "-"))
print("  stopped because        : %s" % (c.get("stopped") or a.get("stopped") or "-"))

# ── WHICH ENGINE ACTUALLY RAN ────────────────────────────────────────────────
# Three independent readings, none of them the flag we asked for. They must agree.
print("\n  WHICH ENGINE ACTUALLY RAN (three independent readings):")
print("    1. requested (LCARS_DRIVE_ENGINE) : %s" % os.environ["ENGINE"])
print("    2. persisted state.json workerBin : %s   <-- the field measured BEATING the env var"
      % (os.environ.get("PERSISTED_BIN") or "(none)"))
print("    3. claude spawns through the shim : %s   (%s; expected %s)"
      % (os.environ["BLOCKED"], os.environ["SHIM_KIND"], os.environ["CLAUDE_EXPECT"]))
exp, got = os.environ["CLAUDE_EXPECT"], int(os.environ["BLOCKED"])
agree = (got == 0) if exp == "0" else (got > 0)
if os.environ.get("PERSISTED_BIN") and os.environ["PERSISTED_BIN"] != os.environ["ENGINE"]:
    agree = False
print("    → %s" % ("all three agree — the engine that ran IS %s" % os.environ["ENGINE"]
                    if agree else
                    "*** THEY DISAGREE — do not trust this cell's engine attribution ***"))
print("    4. per-engine spend below (run.sh usage) is the fourth, and it costs money to be wrong.")

un = a.get("unrecordedQuestions") or []
if un:
    print("\n  QUESTIONS THE RECORD DID NOT SETTLE (align):")
    for q in un: print("    ✗ %s" % q[:200])
gates = c.get("gates") or []
print("\n  AWAITING-HUMAN GATES HIT: %d" % len(gates))
for g in gates:
    print("    · round %s · stage %s · %s" % (g.get("round"), g.get("stage"), g.get("handled")))
    for q in g.get("questions") or []:
        print("        Q: %s" % " ".join(str(q).split())[:220])
print("\n  WORKER USAGE (run.sh usage):")
for line in (os.environ.get("USAGE") or "(none recorded)").splitlines():
    print("    " + line)
print("\n  evidence: %s/standin-log.txt   (every turn, every match, every reply)" % out)
print(bar)
PY
