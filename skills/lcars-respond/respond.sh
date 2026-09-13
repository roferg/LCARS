#!/usr/bin/env bash
#
# lcars respond — answer a Mission's awaiting-human gate, walk-away style.
#
# When a stage escalates (Research >20 questions, Validate scope change, Plan
# Review's 3-round limit, Implement's 3-worker-session cap) it parks the Mission behind
# an awaiting-human gate: awaitingHuman=true in state.json, the question(s) in
# pending.json, and the lcars:awaiting-human label on the issue. This is the
# command the captain uses to answer that gate. It has three subcommands:
#
#   list                       Read-only. Every Mission with awaitingHuman=true
#                              and its pending question(s) — mirrors how
#                              `lcars status` surfaces them. Says so if none.
#
#   show   --mission <id>      Read-only. That Mission's pending question(s)
#                              from pending.json.
#
#   answer --mission <id> --answer "<text>"
#                              Persist the captain's free-form answer next to the
#                              question(s) in answers.json, clear the awaiting-
#                              human gate in state.json (the STAGE IS UNCHANGED —
#                              the Mission stays at the stage that escalated),
#                              and remove the lcars:awaiting-human label, then
#                              hand straight back to the driver
#                              (`run.sh drive --mission <the id>`), which
#                              re-enters that same stage and consumes the answer
#                              instead of re-asking.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN   the gh binary           (default: gh)
#   LCARS_NOW      ISO stamp for the answer (default: now, UTC)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
NOW="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
RELABEL_NOTE=""

# The Mission-Log resolver — its `complete` op folds a parent's verified child
# bug Missions to Done (no per-bug PR) once the consolidated re-verify gate is
# accepted (BUG-E, Model A). respond owns the generic gate clear; it delegates
# the logged-bug fold to resolve-logs so that lifecycle logic stays in one place
# (ADR-002). Env-injected so tests can point at the real script / stub it.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_LOGS_SCRIPT="${LCARS_RESOLVE_LOGS_SCRIPT:-$SELF_DIR/../lcars-resolve-logs/resolve-logs.sh}"
# S180 — the driver this script hands back to once the gate is cleared. Same
# env-injection pattern as the resolve-logs delegate above, so a test can point a
# stub at it and no drive is ever spawned in a suite.
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SELF_DIR/../lcars-run/run.sh}"

# S180 — HOW MANY TIMES AN ANSWER MAY BUY A FRESH PLAN REVIEW BUDGET.
#
# `MAX_REVIEW_ROUNDS` (run.sh) is 3, and NOTHING used to reset `planReviewRound`
# — not this script, not feedback.sh. So once a Mission had escalated once, every
# subsequent failed review round was an immediate human gate: rounds 4, 5 and 6
# all happened on lcars-20260829-002, at a full reviewer cycle each. A captain's
# answer is NEW INFORMATION the reviewer has never seen, so it earns a fresh
# loop.
#
# WHY 3, AND WHY A SEPARATE COUNTER. Resetting alone would remove the ceiling
# entirely — answer, fail three rounds, answer, forever — so the escalations
# themselves are counted and capped independently of the rounds. Three answered
# escalations is at most 3x3 = 9 reviewer rounds, which bounds the spend at
# roughly ten review cycles for one Mission; and by the third time a fresh answer
# has failed to unstick the reviewer, the evidence is that the disagreement is
# not about information the captain can supply, so buying a fourth loop spends
# money to reach the same gate. Past the cap the budget is NOT reset and the very
# next failure escalates, exactly as it does today.
MAX_REVIEW_ESCALATIONS="${LCARS_MAX_REVIEW_ESCALATIONS:-3}"

die() { printf 'lcars respond: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as run.sh / status.sh) -----------
# json_str decodes the common escapes so a question carrying an inner \" prints
# in full (same awk reader as status.sh); json_raw pulls a bare token.
json_str() { # file key
  awk -v k="$2" '
    done { next }
    {
      tok = "\"" k "\""
      p = index($0, tok)
      if (p == 0) next
      rest = substr($0, p + length(tok))
      if (match(rest, /^[ \t]*:[ \t]*"/) == 0) next
      rest = substr(rest, RLENGTH + 1)
      out = ""; i = 1; n = length(rest)
      while (i <= n) {
        c = substr(rest, i, 1)
        if (c == "\\") {
          e = substr(rest, i + 1, 1)
          if      (e == "n") out = out "\n"
          else if (e == "t") out = out "\t"
          else               out = out e
          i += 2; continue
        }
        if (c == "\"") break
        out = out c; i += 1
      }
      print out; done = 1
    }
  ' "$1"
}
json_raw() { # file key
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

# --- escape a string for embedding in JSON (printed) -----------------------
# Escape a string into JSON-string-safe text (no surrounding quotes). Backslash
# and quote first via fast bash substitution; then awk escapes EVERY control
# char (0x01–0x1F) — newline/tab/CR get \n \t \r, the rest \u00XX — so a
# multi-line captain answer yields VALID JSON. jq-free. Order: backslash first.
json_escape() {
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '%s' "$s" | awk '
    BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
    { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
        if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
        else if (c=="\r") printf "\\r"
        else { b=index(MAP,c); if (b>0) printf "\\u%04x",b; else printf "%s",c } } }'
}

# --- read pending.json's questions, one per line (decoded) -----------------
# The canonical pending.json (run.sh's write_pending) puts one "question" per
# line inside the "questions": [ … ] array, so a line-oriented awk pass is
# enough — same jq-free spirit as the rest of LCARS.
read_questions() { # pending.json
  awk '
    /"questions"[[:space:]]*:[[:space:]]*\[/ { inq=1; next }
    inq && /^[[:space:]]*\]/ { inq=0; next }
    inq {
      s=$0
      sub(/^[[:space:]]*/, "", s); sub(/[[:space:]]*$/, "", s)
      sub(/,$/, "", s)
      sub(/^"/, "", s); sub(/"$/, "", s)
      gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s)
      if (s != "") print s
    }
  ' "$1"
}

# --- answers.json, APPEND-ONLY (S180) ---------------------------------------
# Append ONE entry for this answer to $MISSION_DIR/answers.json and re-mirror the
# legacy top-level slot onto the newest entry. See the design note at the call
# site in cmd_answer.
#
# Written in python3 because merging JSON with awk is how a ledger quietly loses
# an entry, and python3 is already a hard dependency of the pipeline this file
# feeds (run.sh's Stage machinery and the viewscreen are both python3-only). If
# it is somehow absent we fall back to EXACTLY the pre-S180 single-slot writer —
# the captain never loses the answer he just typed to a missing interpreter; he
# loses only the history, which is where he already was.
answers_append() { # stage
  local stage="$1" out="$MISSION_DIR/answers.json"
  local qf; qf="$(mktemp)"
  read_questions "$PENDING" >"$qf"
  local py="${LCARS_PYTHON_BIN:-python3}"
  if command -v "$py" >/dev/null 2>&1; then
    if LCARS_A_STAGE="$stage" LCARS_A_AT="$NOW" LCARS_A_TEXT="$ANSWER" \
       "$py" - "$out" "$qf" <<'S180_PY'
import json, os, sys

out, qfile = sys.argv[1], sys.argv[2]
with open(qfile) as fh:
    questions = [ln.rstrip("\n") for ln in fh if ln.strip()]

entry = {
    "stage": os.environ.get("LCARS_A_STAGE", ""),
    "answeredAt": os.environ.get("LCARS_A_AT", ""),
    "answer": os.environ.get("LCARS_A_TEXT", ""),
    "questions": questions,
}

# WHAT IS ALREADY ON DISK. Three shapes are possible and all three must survive:
# the append-only ledger (read the list), a pre-S180 single slot (migrate it into
# the list as the first entry — it is a real answer the captain gave), and
# anything unreadable (start clean rather than refuse; refusing here would lose
# the answer he is giving RIGHT NOW to salvage one that is already corrupt).
prior = []
try:
    with open(out) as fh:
        old = json.load(fh)
    if isinstance(old, dict):
        xs = old.get("answers")
        if isinstance(xs, list):
            prior = [x for x in xs if isinstance(x, dict)]
        elif old.get("answer"):
            prior = [{
                "stage": old.get("stage") or "",
                "answeredAt": old.get("answeredAt") or "",
                "answer": old.get("answer"),
                "questions": [q for q in (old.get("questions") or [])
                              if isinstance(q, str)],
            }]
except Exception:
    prior = []

answers = prior + [entry]
doc = {
    # The legacy single slot, mirroring the NEWEST answer — see the call site.
    "stage": entry["stage"],
    "answeredAt": entry["answeredAt"],
    "answer": entry["answer"],
    "questions": entry["questions"],
    # The ledger. Oldest first; nothing is ever removed.
    "answers": answers,
}
with open(out, "w") as fh:
    json.dump(doc, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
S180_PY
    then
      rm -f "$qf"; return 0
    fi
  fi
  # FALLBACK: the pre-S180 writer, byte for byte.
  local esc; esc="$(json_escape "$ANSWER")"
  {
    echo '{'
    printf '  "stage": "%s",\n' "$stage"
    printf '  "answeredAt": "%s",\n' "$NOW"
    printf '  "answer": "%s",\n' "$esc"
    echo '  "questions": ['
    awk 'NF{ gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); q[++n]=$0 }
         END{ for(i=1;i<=n;i++) printf "    \"%s\"%s\n", q[i], (i<n?",":"") }' \
      "$qf"
    echo '  ]'
    echo '}'
  } >"$out"
  rm -f "$qf"
}

# --- locate .git/lcars/missions (mirrors run.sh / status.sh) ----------------
locate_missions_dir() {
  local gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  MISSIONS_DIR="$gitdir/lcars/missions"
}


# --- S189: solo ownership, the light lock ----------------------------------
# A mission assigned to SOMEONE ELSE on GitHub is READ-ONLY to this laptop's
# write verbs. `lcars respond answer` RECORDS an answer, clears a gate and resumes the drive, so it consults the lock; the READ verbs (status,
# buddy, the viewscreen's reads) never do. The remedy is deliberately a HUMAN act
# on GitHub — the solo protocol's premise is that the captain moves ownership
# where both laptops can see it, and LCARS never takes a mission off anyone.
#
# The library lives in the sibling lcars-run skill dir (the same reach this
# script already makes for the host adapter). A MISSING library leaves the verb
# unenforced — exactly pre-S189 behaviour — rather than refusing blindly, and
# LCARS_OWNER_ENFORCE=0 bypasses the lock for harness debugging.
OWNERSHIP_LIB="${LCARS_OWNERSHIP_LIB:-$SELF_DIR/../lcars-run/ownership.sh}"
[ -f "$OWNERSHIP_LIB" ] && . "$OWNERSHIP_LIB"

# owner_lock_or_die <issue> — refuse with ONE plain line, or return.
# lcars_owner_lock_reason returns 0 (and echoes the line) ONLY when someone else
# demonstrably holds the mission: unassigned, an unreachable forge and an
# unresolvable identity all fall through to "proceed", because a lock that fires
# on uncertainty locks the captain out of his own work.
owner_lock_or_die() { # <issue>
  local r
  command -v lcars_owner_lock_reason >/dev/null 2>&1 || return 0
  r="$(lcars_owner_lock_reason "${1:-}")" || return 0
  [ -n "$r" ] && die "$r"
  return 0
}

# xo_lock_or_die <mission-dir> — refuse with ONE plain line, or return (S201).
# THE SECOND REASON ON THE SAME SEAM. Number One acts on the captain's behalf
# THROUGH these very verbs, so while it holds a mission a second hand on that
# mission is a race with his own first officer. `lcars_xo_lock_reason` returns 0
# (and echoes the line) ONLY when the mission's RECORDED state says
# numberOne.status is `engaged`; no state, no key, stood-down and finished all
# fall through to "proceed", exactly like the owner lock's posture, and
# LCARS_XO_ENFORCE=0 bypasses it. The remedy is `lcars xo off <id>`.
xo_lock_or_die() { # <mission-dir>
  local r
  command -v lcars_xo_lock_reason >/dev/null 2>&1 || return 0
  r="$(lcars_xo_lock_reason "${1:-}")" || return 0
  [ -n "$r" ] && die "$r"
  return 0
}

# --- locate a single mission ------------------------------------------------
locate_mission() { # id
  locate_missions_dir
  MISSION_DIR="$MISSIONS_DIR/$1"
  STATE="$MISSION_DIR/state.json"
  PENDING="$MISSION_DIR/pending.json"
  [ -d "$MISSION_DIR" ] || die "no mission '$1' under .git/lcars/missions/ — check the id."
  [ -f "$STATE" ]       || die "mission '$1' has no state.json — its state is corrupt."
}

# --- state.json field editing (one-field-per-line; same as run.sh) ----------
state_del() { # key — drop the field's line if present
  local tmp; tmp="$(mktemp)"
  grep -v "\"$1\"[[:space:]]*:" "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}
# Add or replace a bare field (true/false/number). Same one-field-per-line
# convention, and the same implementation, as run.sh's state_set_raw.
state_set_raw() { # key token
  state_del "$1"
  local tmp; tmp="$(mktemp)"
  K="$1" V="$2" awk 'NR==1{print; printf "  \"%s\": %s,\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# --- gh: remove the awaiting-human overlay, best-effort ---------------------
# Tolerant by design: gh is happy to remove a label that isn't applied, and a
# missing gh / failed edit never blocks the local clear — it just leaves a note.
# We never pre-query the issue's labels to "fix" the not-applied case.
gh_remove_awaiting() {
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null) RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped label drop (local-only mission)."; return 0 ;;
  esac
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    "$GH_BIN" issue edit "$issue" --remove-label "lcars:awaiting-human" >/dev/null 2>&1 \
      || RELABEL_NOTE="  ⚠ gh issue edit failed — drop lcars:awaiting-human on #$issue by hand."
  else
    RELABEL_NOTE="  ⚠ gh not found — drop lcars:awaiting-human on #$issue by hand."
  fi
}

# === subcommand: list =======================================================
# Scan every mission; print the ones awaiting a human with their question(s).
cmd_list() {
  locate_missions_dir
  if [ ! -d "$MISSIONS_DIR" ]; then
    echo "No missions awaiting your input."
    exit 0
  fi

  local found=0 s id stage issue pend
  shopt -s nullglob
  for s in "$MISSIONS_DIR"/*/state.json; do
    [ "$(json_raw "$s" awaitingHuman)" = "true" ] || continue
    found=$((found + 1))
    id="$(json_str "$s" id)"; [ -n "$id" ] || id="$(basename "$(dirname "$s")")"
    stage="$(json_str "$s" stage)"
    issue="$(json_raw "$s" githubIssue)"
    case "$issue" in ''|null) issue="-" ;; *) issue="#$issue" ;; esac

    # state.json.stage is the resume pointer (e.g. "align"); pending.json holds
    # the true in-flight stage the card is stuck in (e.g. "research"), matching
    # the board label. Show that so this view agrees with the Kanban column.
    pend="$(dirname "$s")/pending.json"
    if [ -f "$pend" ]; then
      pstage="$(json_str "$pend" stage)"
      [ -n "$pstage" ] && stage="$pstage"
    fi

    [ "$found" -eq 1 ] && echo "LCARS — Missions awaiting your input"
    echo
    printf '  %s (%s) — stage: %s\n' "$id" "$issue" "${stage:-unknown}"
    if [ -f "$pend" ]; then
      while IFS= read -r q; do
        [ -n "$q" ] && echo "    • $q"
      done < <(read_questions "$pend")
    else
      local pq; pq="$(json_str "$s" pendingQuestion)"
      [ -n "$pq" ] && echo "    • $pq"
    fi
  done
  shopt -u nullglob

  if [ "$found" -eq 0 ]; then
    echo "No missions awaiting your input."
    exit 0
  fi
  echo
  echo "Answer one with:"
  echo "  bash $SELF_DIR/respond.sh answer --mission <id> --answer \"<your answer>\""
  exit 0
}

# === subcommand: show =======================================================
# Print one Mission's pending question(s).
cmd_show() {
  locate_mission "$MISSION_ID"
  [ -f "$PENDING" ] || die "mission '$MISSION_ID' has no pending question — nothing to answer."

  local stage; stage="$(json_str "$PENDING" stage)"
  echo "LCARS — pending question(s) for $MISSION_ID (stage: ${stage:-unknown})"
  echo
  local any=0 q
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    any=1; echo "  • $q"
  done < <(read_questions "$PENDING")
  [ "$any" -eq 1 ] || die "pending.json for '$MISSION_ID' lists no questions — its gate is malformed."
  echo
  echo "Answer with:"
  echo "  bash $SELF_DIR/respond.sh answer --mission $MISSION_ID --answer \"<your answer>\""
  exit 0
}

# === subcommand: answer =====================================================
# Persist the answer next to the question(s), clear the gate (stage unchanged),
# drop the awaiting-human label.
cmd_answer() {
  locate_mission "$MISSION_ID"
  # S189: the light lock. ANSWERING is a write (it clears the gate and resumes
  # the drive), so it is locked; `respond list` and `respond show` are READS and
  # are never blocked — a captain must always be able to SEE what a teammate's
  # mission is waiting on.
  owner_lock_or_die "$(json_raw "$STATE" githubIssue)"
  xo_lock_or_die "$MISSION_DIR"
  [ -n "$ANSWER" ] || die "no answer — pass --answer \"<your answer>\" with the captain's response."

  # Only a Mission actually waiting on a human can be answered.
  [ "$(json_raw "$STATE" awaitingHuman)" = "true" ] \
    || die "mission '$MISSION_ID' is not awaiting a human — there is nothing to answer."
  [ -f "$PENDING" ] || die "mission '$MISSION_ID' has awaitingHuman set but no pending.json — its gate is corrupt."

  local stage; stage="$(json_str "$PENDING" stage)"; stage="${stage:-unknown}"

  # Persist the answer next to the question(s) so the resuming stage consumes it.
  #
  # S180 — APPEND-ONLY. This used to be a SINGLE SLOT: `{stage, answeredAt,
  # answer, questions}`, rewritten from scratch on every answer. MEASURED on
  # lcars-20260829-002: the captain answered the same Plan Review escalation
  # three times, and each answer ERASED the one before it. Every Stage that reads
  # this file was therefore reading his most recent sentence with no idea two
  # earlier ones existed — and a later answer that only REFINED an earlier one
  # ("…and keep the rest as I said") silently destroyed the thing it referred to.
  #
  # So the file is now a LEDGER: `answers` is an ordered list, one entry per
  # answer, each carrying the stage and the exact questions it was answering.
  # Nothing is ever removed from it.
  #
  # THE LEGACY SLOT STAYS, mirroring the NEWEST entry. That is not decoration:
  # several consumers read the top-level `answer` / `stage` / `questions` keys
  # directly (run.sh's reconcile fallback via `json_str`, and every prompt that
  # lists this file by path), and the operative answer is the latest one, so the
  # cheap reader keeps getting the right value with no change. An OLD single-slot
  # file already on disk — every Mission in flight — is migrated into the list on
  # the next answer rather than discarded.
  answers_append "$stage"

  # === S180: A CAPTAIN'S ANSWER BUYS A FRESH PLAN REVIEW BUDGET ============
  # See the MAX_REVIEW_ESCALATIONS note at the top for why, and why it is capped
  # by a SEPARATE counter rather than by letting the rounds run. Only the
  # plan-review gate is touched; every other gate leaves both fields alone.
  REVIEW_NOTE=""
  if [ "$stage" = "plan-review" ]; then
    local escs; escs="$(json_raw "$STATE" planReviewEscalations)"
    case "$escs" in ''|*[!0-9]*) escs=0 ;; esac
    escs=$((escs + 1))
    state_set_raw planReviewEscalations "$escs"
    if [ "$escs" -le "$MAX_REVIEW_ESCALATIONS" ]; then
      state_set_raw planReviewRound 0
      REVIEW_NOTE="  Plan Review gets a fresh review round on your answer (answered escalation $escs of $MAX_REVIEW_ESCALATIONS)."
    else
      REVIEW_NOTE="  Plan Review budget NOT reset: $MAX_REVIEW_ESCALATIONS answered escalations is the cap, and this is $escs. The next failed round comes straight back to you — a fourth loop would spend a full review cycle to reach this same gate."
    fi
  fi

  # RECONCILE design gate (BUG-043/055): a reconcile design question marks the
  # mission with a dedicated marker file (reconcile-design-question.txt) so this
  # gate is distinguishable from a GENERIC awaiting-human gate. For it we ALSO:
  #   • write the captain's answer to a DEDICATED store the reconcile resume reads
  #     (reconcile-answer.txt) — so a later, unrelated answers.json never interferes;
  #   • RESET the reconcile round budget (drop reconcileRound) and clear the
  #     escalated reconcileStatus, so the post-answer resume starts with a fresh
  #     RECONCILE_MAX (the decision-heal + re-merge verify need their own rounds);
  #   • clear the marker.
  # Generic gates are untouched by all of this.
  RECONCILE_NOTE=""
  if [ -f "$MISSION_DIR/reconcile-design-question.txt" ]; then
    printf '%s\n' "$ANSWER" >"$MISSION_DIR/reconcile-answer.txt"
    state_del reconcileRound
    state_del reconcileStatus
    rm -f "$MISSION_DIR/reconcile-design-question.txt"
    RECONCILE_NOTE="  Recorded your reconcile design decision and reset the reconcile budget."
  fi

  # Clear the gate — but DO NOT touch the stage. The Mission stays parked at the
  # stage that escalated; `lcars run` re-enters it and consumes answers.json.
  state_del awaitingHuman
  state_del pendingQuestion

  gh_remove_awaiting

  # If this Mission is a logged-bug PARENT whose consolidated re-verify gate we
  # just cleared, fold its verified child bug Missions to Done (Model A, BUG-E):
  # the children ride the parent's PR, so they reach Done WITHOUT a per-bug PR.
  # Delegated to resolve-logs (it owns the fold) and STRICTLY best-effort — it is
  # a clean no-op for an ordinary escalation (no verified linked children), so it
  # never affects a non-logged-bug answer. Never blocks clearing the gate.
  #
  # Best-effort does NOT mean silent (S165). The fold can succeed while a piece of
  # it fails — a child folded to Done whose issue the forge refused to close leaves
  # resolve-logs printing "⚠ folded <bid> but could not close its issue #<n> — close
  # it by hand." Both streams used to go to /dev/null here, so on the surface the
  # gate's own text points the captain at (`lcars answer respond --mission …`, and
  # the viewscreen's respond endpoint behind it) that note died: children went Done,
  # their issues stayed OPEN, and nothing was said. Capture the output, pass the ⚠
  # lines through, and quote the fold's OWN summary line so the success case is not
  # silent either — never a canned claim, so an ordinary escalation (a clean no-op)
  # still says nothing about bugs it did not fold.
  #
  # No pipes anywhere below: this runs under `set -o pipefail`, and a pipe into an
  # early-exiting reader already broke this fold path once via SIGPIPE (see
  # child_fix_on_branch in resolve-logs.sh). Here-strings only.
  #
  # …and the LOUDEST case was the silent one (S165 fix round 2). A child whose fix
  # is NOT on the parent branch is REFUSED by the fold's premise check, and
  # cmd_complete then prints its refusal on stderr and exits NON-ZERO *before* the
  # `Folded N …` line. That refusal carries no `⚠` glyph, so neither filter above
  # matched it: accepting a batch where one bug's fix had vanished printed the
  # ordinary readout and ZERO bytes of stderr — no refusal, and no word about the
  # siblings that DID fold — while `lcars approve` said both. So key the second
  # filter off the fold's EXIT STATUS, not off a glyph: a non-zero fold means
  # resolve-logs declined to complete something and everything it said explains
  # why, so quote that whole block. Its own words already carry both halves
  # ("… NOT on the parent branch: <id>" and "N sibling(s) folded normally"), so
  # nothing here is invented — on rc 0 the ⚠-only filter is unchanged and a clean
  # no-op still says nothing.
  FOLD_NOTE=""; FOLD_WARN=""
  if [ -f "$RESOLVE_LOGS_SCRIPT" ]; then
    # rc is deliberately still ignored for CONTROL FLOW, exactly as before: the gate
    # is already cleared and a fold failure re-raises the gate in STATE, never by
    # blocking the answer. We only read it to decide how much to say.
    FOLD_RC=0
    FOLD_OUT="$(LCARS_GH_BIN="$GH_BIN" bash "$RESOLVE_LOGS_SCRIPT" complete \
                  --parent "$MISSION_ID" 2>&1)" || FOLD_RC=$?
    FOLD_WARN="$(grep '⚠' <<<"$FOLD_OUT")" || true
    if [ "$FOLD_RC" -ne 0 ]; then
      # The diagnostic block runs from resolve-logs' own first `lcars resolve-logs:`
      # line to the end of its output (its trailing detail lines are indented and
      # carry no anchor of their own). A ⚠ note from a sibling that folded fine is
      # printed BEFORE that block, so the two captures never overlap.
      FOLD_REFUSAL="$(awk '/^lcars resolve-logs: /{ blk=1 } blk { print }' \
                        <<<"$FOLD_OUT")" || true
      if [ -n "$FOLD_REFUSAL" ] && [ -n "$FOLD_WARN" ]; then
        FOLD_WARN="$FOLD_WARN
$FOLD_REFUSAL"
      elif [ -n "$FOLD_REFUSAL" ]; then
        FOLD_WARN="$FOLD_REFUSAL"
      fi
    fi
    FOLD_NOTE="$(awk '/^Folded /{ print "  " $0; exit }' <<<"$FOLD_OUT")" || true
  fi

  echo "RESPOND: answered $MISSION_ID"
  echo "  Recorded your answer in answers.json (appended — earlier answers kept; stage unchanged)."
  echo "  Stage:  $stage"
  [ -n "$REVIEW_NOTE" ] && echo "$REVIEW_NOTE"
  [ -n "$RECONCILE_NOTE" ] && echo "$RECONCILE_NOTE"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  [ -n "$FOLD_NOTE" ] && echo "$FOLD_NOTE"
  # Warnings last and on stderr, after the readout they qualify.
  [ -n "$FOLD_WARN" ] && printf '%s\n' "$FOLD_WARN" >&2

  # === S180: HAND BACK TO THE DRIVER ======================================
  # The gate is clear and the Mission is sitting at the stage that escalated,
  # able to run. It used to just SAY so and stop, which cost the captain three
  # manual restarts on lcars-20260829-002 — every answer he gave needed a second
  # command before anything happened. Re-enter the driver here instead: it is the
  # same subprocess he would have typed, and `exec` means his terminal follows
  # the run he just unblocked.
  #
  # NO LOOP IS POSSIBLE. The driver never calls this script; it halts at the next
  # gate and returns. A Mission that is NOT drivable never reaches this line —
  # cmd_answer refuses above unless awaitingHuman was true, and the gate has just
  # been cleared, so the resume is always from a cleared gate.
  #
  # TWO CASES OPT OUT:
  #   • a logged-bug CHILD (parentMission set). Its resume is the PARENT's
  #     resolve-logs batch, not a standalone drive on the child — driving the
  #     child alone is what the board deliberately avoids. Say what to run.
  #   • LCARS_RESPOND_RESUME=0. The viewscreen sets it: its respond endpoint
  #     calls this script BLOCKING and then spawns its own detached driver
  #     (BUG-028), so resuming here would hang an HTTP handler for a whole run.
  local parent; parent="$(json_str "$STATE" parentMission)"
  if [ -n "$parent" ]; then
    echo "  This is a logged bug against $parent — resume the batch with:"
    echo "    bash $RESOLVE_LOGS_SCRIPT --parent $parent"
    exit 0
  fi
  if [ "${LCARS_RESPOND_RESUME:-1}" = "0" ] || [ ! -f "$RUN_SCRIPT" ]; then
    echo "  Resume $stage with:"
    echo "    bash $RUN_SCRIPT drive --mission $MISSION_ID"
    exit 0
  fi
  echo "  Resuming $stage now — it consumes your answer instead of re-asking."
  # A CHILD, NOT AN `exec`, and the driver's exit code is deliberately NOT this
  # script's. `respond` exiting non-zero has one meaning to every caller — "your
  # answer was NOT recorded" — and the viewscreen's blocking dispatch raises on
  # it. The answer IS recorded by the time we get here, so a Stage that then
  # fails must surface as the driver's own error text (which streams to the same
  # terminal), never as a false "your answer was rejected".
  bash "$RUN_SCRIPT" drive --mission "$MISSION_ID" || \
    echo "  ⚠ the resumed drive exited non-zero — your answer is recorded; re-run: bash $RUN_SCRIPT drive --mission $MISSION_ID" >&2
  exit 0
}

# --- dispatch --------------------------------------------------------------
SUB="${1:-}"; [ $# -gt 0 ] && shift

MISSION_ID=""; ANSWER=""; ANSWER_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mission)   MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*) MISSION_ID="${1#--mission=}"; shift ;;
    --answer)    ANSWER="${2:-}"; ANSWER_SET=1; shift 2 ;;
    --answer=*)  ANSWER="${1#--answer=}"; ANSWER_SET=1; shift ;;
    *)           die "unknown argument: $1" ;;
  esac
done

case "$SUB" in
  show|answer) [ -n "$MISSION_ID" ] || die "no mission id — pass --mission <id>." ;;
esac

case "$SUB" in
  list)   cmd_list ;;
  show)   cmd_show ;;
  answer) cmd_answer ;;
  ''|*)   die "unknown subcommand '${SUB:-}'. Usage: respond.sh list | show --mission <id> | answer --mission <id> --answer \"<text>\"." ;;
esac
