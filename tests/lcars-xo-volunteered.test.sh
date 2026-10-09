#!/usr/bin/env bash
# tests/lcars-xo-volunteered.test.sh — S263, "connect the severed lanes".
#
# WHAT WAS MEASURED, before a line of this was written. In S262 Number One filed
# ZERO bugs across 65 criteria while the captain's human buddy filed three. It
# has three filing lanes and TWO WERE SEVERED:
#
#   LANE 1 — `volunteered[]`, severed BY ACCIDENT. Fed the RAW verdict,
#   `xo-logs.py` already emits a `GAP` record and a well-formed bug PRD for a
#   volunteered find, and `xo-filed.py` already keeps it out of the send-back
#   sentence. The break was one missing line: `xo-score.py` builds its output as
#   a hand-written literal dict and never copied the key — and the RAW verdict is
#   deleted by `xo_rm_work`, while `xo-logs.py` is handed the SCORED file. The
#   data was not dropped, it was DESTROYED.
#
#   LANE 2 — `untested` + `cause: "product"`, NEVER ASKED FOR. `xo-logs.py` files
#   a high-impact blind row whose recorded cause is `product` (the build ships no
#   way to do the thing) and `xo-score.py` stamps that cause onto the ledger — but
#   `"cause"` was named NOWHERE in the 61,740-byte assembled prompt, so the
#   reviewer never declared it. 11 of 11 blind rows last night carried no cause.
#   The lane had never fired once.
#
#   AND A HOLE. The volunteered gate asked only for "a title OR a saw", so
#   {"title": "The whole app feels slow", "saw": "it felt sluggish"} filed a bug
#   with no evidence of any kind.
#
# THE RIGHT SHAPE, and the thing every check below is pointed at: **the reviewer
# can FILE what no criterion covers, and still cannot GRADE on it.** The grade
# fence is not being relaxed — only the filing opens.
#
# EVERY CHECK HAS ITS CONTROL. A pass-through is proved by a scorer with the
# pass-through MUTATED OUT; a citation guard by the same find WITH a shot; a
# declared cause by the same row with the cause absent and with a word nobody
# recognises. Nine probes passed vacuously in one night of this round; a check
# that cannot fail measures nothing.
#
# ZERO SPEND: a PATH shim fakes BOTH engines (the engine resolves from the
# request body, $LCARS_WORKER_BIN and a persisted state.json workerBin — an env
# var alone has been measured losing) and counts every call. The count is
# asserted at the end.
#
# Usage: bash tests/lcars-xo-volunteered.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="$REPO_ROOT/skills/lcars-xo"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
SCORE_PY="$XO/xo-score.py"
LOGS_PY="$XO/xo-logs.py"
EVAL_MD="$XO/prompts/evaluate.md"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND: a shim that fakes BOTH engines and counts every call -------
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
export SPEND_LOG="$TMPROOT/spend.log"
: >"$SPEND_LOG"
for eng in claude copilot; do
  cat >"$SHIM/$eng" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$eng" "\$*" >>"$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"

echo "lcars xo — THE SEVERED LANES: a find nobody wrote a criterion for"

RS=$'\x1f'

# ===========================================================================
# THE RIG — a criteria.json, a shots dir with real files, and verdicts that
# differ in exactly ONE thing each, so every control isolates one variable.
# ===========================================================================
R="$TMPROOT/rig"; mkdir -p "$R/shots"
cat >"$R/criteria.json" <<'CJ'
{"criteria": [
  {"id": "prd-1", "text": "relay file stores the title it was given",
   "source": "prd", "impact": "high"},
  {"id": "prd-2", "text": "relay publish names the host from the config",
   "source": "prd", "impact": "high"}
]}
CJ
printf 'usage: relay [file|list|publish]\n' >"$R/shots/01-help.txt"
printf '$ relay publish\nposting to api.github.com\n' >"$R/shots/02-publish.txt"
# THINGS THAT EXIST AND ARE NOT A RECORD OF THIS LOOK (S263 fix round 2, D2).
# Every one of these was measured CITING a complete bug in fix round 1: the rung
# asked `os.path.exists(v)` on the raw value, against the PROCESS CWD, with no
# `isfile`, no size and no confinement.
: >"$R/shots/00-empty.txt"                    # a real file, inside, ZERO BYTES
mkdir -p "$R/shots/sub"                       # a DIRECTORY, inside the shots dir
printf 'not this look\n' >"$R/outside.txt"    # one level ABOVE the shots dir
# AND THE FIXTURES FOR "INSIDE MEANS UNDER" (S263 fix round 3, FIX 2). A record
# the reviewer genuinely saved in a SUBDIRECTORY of its own shots directory was
# basenamed before it was resolved, looked for at `shots/x.txt`, and the honest
# find was REFUSED. Beside it, the three ways "under" must still mean under:
mkdir -p "$R/shots/deep/a/b"
printf 'a record, saved deeper\n' >"$R/shots/deep/a/b/07-footer.txt"
mkdir -p "$R/shots-evil"                      # THE PREFIX TRAP: a sibling whose
printf 'not this look\n' >"$R/shots-evil/x.txt"  # name STARTS with the shots dir
ln -sfn "$R/outside.txt" "$R/shots/09-link.txt"  # a symlink INSIDE, pointing OUT

# A verdict with ONE contracted gap (so the contracted lane is measured beside
# the new one) and ONE volunteered find that CITES A SHOT.
cat >"$R/verdict.json" <<'VJ'
{"score": "medium",
 "recommendation": "send-back",
 "summary": "I ran the CLI and read what it printed.",
 "criteria": [
   {"id": "prd-1", "text": "relay file stores the title it was given",
    "impact": "high", "status": "gap", "evidence": "transcript",
    "checkedBy": "cli", "shot": "01-help.txt",
    "sawInstead": "a record with an empty title",
    "note": "I filed nonce-7 and listed it back with no title",
    "action": "Ran relay.py file then relay.py list."},
   {"id": "prd-2", "text": "relay publish names the host from the config",
    "impact": "high", "status": "met", "evidence": "transcript",
    "checkedBy": "cli", "shot": "02-publish.txt",
    "note": "it printed the configured host",
    "action": "Ran relay.py publish."}
 ],
 "gaps": [
   {"title": "file stores no title", "expected": "the title it was given",
    "saw": "a record with an empty title", "shots": ["01-help.txt"],
    "kind": "contradiction", "criterion": "prd-1"}
 ],
 "volunteered": [
   {"title": "the README documents no command at all",
    "expected": "the README to name the commands the CLI actually ships",
    "saw": "the README names file and list and never mentions publish",
    "shots": ["01-help.txt"], "evidence": "transcript", "checkedBy": "cli",
    "note": "nothing the captain wrote down covers the README's command list"}
 ],
 "escalations": [], "alsoChecked": [], "couldNot": []}
VJ

# THE SAME VERDICT, volunteered lane EMPTY — the control for the grade fence.
"$PY" - "$R/verdict.json" "$R/verdict-none.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["volunteered"] = []
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYEOF

# THE SAME VERDICT, volunteered find stripped of EVERY citation — the hole the
# spike walked through. One variable: the evidence.
"$PY" - "$R/verdict.json" "$R/verdict-bare.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["volunteered"] = [{"title": "The whole app feels slow",
                     "saw": "it felt sluggish"}]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYEOF

run_score() { # <scorer.py> <verdict-in> <scored-out>
  "$PY" "$1" "$2" "$R/criteria.json" "$3" >/dev/null 2>&1
}
run_logs() { # <scored-verdict> <outdir>
  mkdir -p "$2"
  "$PY" "$LOGS_PY" "$1" "$R/criteria.json" "$2" "$R/shots" 2>/dev/null
}
key_is_there() { # <scored.json>
  "$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = d.get("volunteered")
sys.exit(0 if isinstance(v, list) and v and isinstance(v[0], dict)
         and v[0].get("title") else 1)' "$1"
}

# THE CONTROL SCORER — this branch's own xo-score.py with the ONE pass-through
# line MUTATED OUT. Not an old git revision: once this session is committed a
# git-revision control would silently become the NEW scorer and stop firing.
# The mutation is verified to have removed something before it is trusted.
OLD_SCORE="$TMPROOT/old-score.py"
grep -v 'S263 PASS-THROUGH' "$SCORE_PY" >"$OLD_SCORE"

echo ""
echo "1. LANE 1 — the key survives the scorer (and the control proves it used not to)"

run_score "$SCORE_PY" "$R/verdict.json" "$R/scored.json"
run_score "$OLD_SCORE" "$R/verdict.json" "$R/scored-old.json"

check "1a. the scorer produced a file at all" '[ -s "$R/scored.json" ]'
check "1b. THE BEHAVIOUR — the volunteered entry survives scoring, key intact" \
  'key_is_there "$R/scored.json"'
check "1c. …and its own fields survive with it, not just the key" \
  '"$PY" -c "
import json,sys
v=json.load(open(sys.argv[1]))[\"volunteered\"][0]
for k in (\"title\",\"expected\",\"saw\",\"shots\",\"evidence\",\"note\"):
    assert v.get(k), (k, v)
" "$R/scored.json"'
# THE MUTATION IS REAL BEFORE IT IS A CONTROL.
check "1d. the control scorer really is the one-line mutation (it lost the line)" \
  '[ "$(grep -c "S263 PASS-THROUGH" "$SCORE_PY")" -ge 1 ] &&
   [ "$(grep -c "S263 PASS-THROUGH" "$OLD_SCORE")" = "0" ] &&
   [ -s "$R/scored-old.json" ]'
check "1e. CONTROL — the same verdict through the UNPATCHED scorer loses the key" \
  '! key_is_there "$R/scored-old.json"'

echo ""
echo "2. LANE 1 — the SCORED file files a bug, with a PRD log.sh would accept"

PLAN="$(run_logs "$R/scored.json" "$R/logs")"
PLAN_OLD="$(run_logs "$R/scored-old.json" "$R/logs-old")"

gaps_in() { printf '%s\n' "$1" | grep -c "^GAP" || true; }
vol_rec()  { printf '%s\n' "$1" | awk -v RS2="$RS" 'index($0, RS2 "volunteered-1" RS2)'; }
vol_rec_stdin() { awk -v RS2="$RS" 'index($0, RS2 "volunteered-1" RS2)'; }

check "2a. THE BEHAVIOUR — two bugs file off the SCORED verdict: the gap AND the volunteered find" \
  '[ "$(gaps_in "$PLAN")" = "2" ]'
check "2b. the volunteered one is keyed volunteered-1, because there is no criterion" \
  '[ -n "$(vol_rec "$PLAN")" ]'
check "2c. CONTROL — through the unpatched scorer the SAME verdict files only the gap" \
  '[ "$(gaps_in "$PLAN_OLD")" = "1" ] && [ -z "$(vol_rec "$PLAN_OLD")" ]'
check "2d. a GAP record for a volunteered find still has EXACTLY seven fields" \
  '[ "$(vol_rec "$PLAN" | tr -cd "$RS" | wc -c | tr -d " ")" = "6" ]'
check "2e. its PRD is on disk where the record says it is" \
  'p="$(vol_rec "$PLAN" | cut -d"$RS" -f3)"; [ -f "$p" ]'
# AC #1 IS THE ONE PART THAT CANNOT BE WRONG — log.sh's own rule. The validator
# reads the FIRST BULLET under the Acceptance Criteria heading.
ac1_of() { # <prd>
  awk '/^\*\*Acceptance Criteria:\*\*/{f=1; next} f && /^- /{sub(/^- /,""); print; exit}' "$1"
}
check "2f. THE RULE — its AC #1 is literally an Observed live: line" \
  'p="$(vol_rec "$PLAN" | cut -d"$RS" -f3)";
   printf "%s" "$(ac1_of "$p")" | grep -Eqi "^observed live[[:space:]]*:"'
check "2g. …and the PRD carries all six sections log.sh requires, Type: bug included" \
  'p="$(vol_rec "$PLAN" | cut -d"$RS" -f3)";
   grep -q "^# Mission: " "$p" && grep -q "^\*\*Type:\*\* bug$" "$p" &&
   grep -q "^\*\*Seam:\*\*" "$p" && grep -q "^\*\*Goal:\*\*" "$p" &&
   grep -q "^\*\*Acceptance Criteria:\*\*" "$p" &&
   grep -q "^\*\*Out of Scope:\*\*" "$p" && grep -q "^\*\*Constraints:\*\*" "$p"'
check "2h. …and it says plainly that nobody asked for it and it moved no grade" \
  'p="$(vol_rec "$PLAN" | cut -d"$RS" -f3)";
   grep -qi "not asked for" "$p" &&
   tr "\n" " " <"$p" | tr -s " " | grep -qi "did not change the grade"'
check "2i. the CONTRACTED bug is still #1 and byte-identical to the no-volunteered run" \
  'run_logs "$R/scored-none.json" "$R/logs-x" >/dev/null 2>&1 || true;
   run_score "$SCORE_PY" "$R/verdict-none.json" "$R/scored-none.json";
   run_logs "$R/scored-none.json" "$R/logs-none" >/dev/null;
   cmp -s "$R/logs/1.md" "$R/logs-none/1.md"'

echo ""
echo "3. THE HOLE — an unevidenced volunteered find is REFUSED, by name"

run_score "$SCORE_PY" "$R/verdict-bare.json" "$R/scored-bare.json"
PLAN_BARE="$(run_logs "$R/scored-bare.json" "$R/logs-bare")"

check "3a. the bare find survived the scorer (so the refusal is the GUARD's, not the scorer's)" \
  'key_is_there "$R/scored-bare.json"'
check "3b. THE BEHAVIOUR — it is NOT filed: only the contracted gap files" \
  '[ "$(gaps_in "$PLAN_BARE")" = "1" ] && [ -z "$(vol_rec "$PLAN_BARE")" ]'
check "3c. …and the refusal is SAID, not silent" \
  'printf "%s\n" "$PLAN_BARE" | grep -q "^REFUSED"'
check "3d. …and the refusal quotes the find, so the captain knows WHICH one" \
  'printf "%s\n" "$PLAN_BARE" | grep "^REFUSED" | grep -qi "feels slow"'
check "3e. THE CURE — the reason NAMES the citation that is missing" \
  'r="$(printf "%s\n" "$PLAN_BARE" | grep "^REFUSED")";
   printf "%s" "$r" | grep -qi "shot" &&
   printf "%s" "$r" | grep -qi "transcript" &&
   printf "%s" "$r" | grep -qiE "file"'
# AND THE WORDS AND THE BEHAVIOUR AGREE (S263 fix round 2, D3). Fix round 1\'s
# refusal offered `testQuote` as a way in while its own ladder refused
# `Segmentation fault` and `error: unknown command "publish"` — honest machine
# output — and admitted "I looked at config.yaml and it was wrong", an opinion.
# The route is GONE, so the sentence must not advertise it: a guard that names a
# door it has bricked up only loses finds.
check "3e2. THE RESTRUCTURE — and it does NOT offer a quoted line as a way in" \
  'r="$(printf "%s\n" "$PLAN_BARE" | grep "^REFUSED")";
   ! printf "%s" "$r" | grep -qi "testQuote"'
check "3f. CONTROL — the SAME find WITH a cited shot is accepted and files" \
  '"$PY" - "$R/verdict-bare.json" "$R/verdict-cited.json" <<PYE
import json, sys
d = json.load(open(sys.argv[1]))
d["volunteered"][0]["shots"] = ["01-help.txt"]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYE
   run_score "$SCORE_PY" "$R/verdict-cited.json" "$R/scored-cited.json";
   P="$(run_logs "$R/scored-cited.json" "$R/logs-cited")";
   [ "$(gaps_in "$P")" = "2" ] && [ -n "$(vol_rec "$P")" ] &&
     ! printf "%s\n" "$P" | grep -q "^REFUSED"'
check "3g. CONTROL — a bare EVIDENCE WORD with no file behind it is still refused" \
  '"$PY" - "$R/verdict-bare.json" "$R/verdict-word.json" <<PYE
import json, sys
d = json.load(open(sys.argv[1]))
d["volunteered"][0]["evidence"] = "transcript"
d["volunteered"][0]["checkedBy"] = "cli"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYE
   run_score "$SCORE_PY" "$R/verdict-word.json" "$R/scored-word.json";
   P="$(run_logs "$R/scored-word.json" "$R/logs-word")";
   [ -z "$(vol_rec "$P")" ] && printf "%s\n" "$P" | grep -q "^REFUSED"'
# ── THE SECOND LADDER IS GONE (S263 fix round 2, D3) ────────────────────────
#
# `testQuote` used to be a citation route of its own, judged by a SHAPE test on
# the words — and it was measured BACKWARDS: it CITED `"I looked at config.yaml
# and it was wrong"`, `"the README does not list publish and/or list"` and
# `"and/or"`, and REFUSED `error: unknown command "publish"`, `Segmentation
# fault` and `Traceback (most recent call last)`. It admitted an opinion with a
# slash in it and threw away honest machine output without one. Its real rule (a
# prompt character, or a 5-char token containing `_ :: -- /` or `.<alnum>`) was
# written down nowhere, so for that whole class it was unsatisfiable on purpose.
#
# That is the S147/S156/S188 failure class — a rung that judges English — and
# the cure for it has never once been the next heuristic. There is ONE rung now,
# and it asks a question about a RECORD: is this a regular, non-empty file inside
# this look\'s own shots directory? A quoted line is not one, so it is not a way
# in, and the ask no longer offers it.
check "3h. THE RESTRUCTURE — a quoted test line is no longer a way in at all" \
  '"$PY" - "$R/verdict-bare.json" "$R/verdict-quote.json" <<PYE
import json, sys
d = json.load(open(sys.argv[1]))
d["volunteered"][0]["testQuote"] = "FAIL test_readme_lists_publish"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYE
   run_score "$SCORE_PY" "$R/verdict-quote.json" "$R/scored-quote.json";
   P="$(run_logs "$R/scored-quote.json" "$R/logs-quote")";
   [ -z "$(vol_rec "$P")" ] && printf "%s\n" "$P" | grep -q "^REFUSED"'
# DELETED, not renamed: no EXECUTABLE line of the filer names the shape test or
# any of its four constants. The comment block that records why it is gone is
# exactly what should survive, so only code is checked.
check "3h2. …and the SECOND LADDER and its constants are DELETED, not patched again" \
  '[ -z "$(grep -n "vol_quote\|VOL_QUOTE_" "$LOGS_PY" | grep -v "^[0-9]*:[[:space:]]*#")" ]'
# ── THE CITATION TABLE: PRESENCE IS NOT A CITATION (S263 fix round 1, D1/D3) ─
#
# WHY THIS TABLE EXISTS AND 3g DID NOT CATCH IT. 3g is titled "a bare EVIDENCE
# WORD with no file behind it is still refused" and it exercises only the
# `evidence` key — which is the ONE key deliberately left OFF the guard's list.
# So it passed for a reason unrelated to the property it names, and the first cut
# of the guard shipped fielding PRESENCE: it looped the citation fields and took
# the first truthy value, so {"transcript": "it felt sluggish when I used it"},
# {"evidencePath": "n/a"} and {"testQuote": "nothing, I did not run a test"} all
# FILED a bug. The price of an evidence-free opinion moved from zero words to ONE
# word. These rows are where a model with nothing to screenshot actually puts the
# word, and the CITED rows are the honest cases that must not regress.
#
# The bar is "does this NAME A RECORD OF THIS LOOK", never "does this sentence
# sound like evidence" and never "does this value look like a path". ONE rung,
# one question, and it is a question about a record and not about words: the name
# is taken down to its basename, resolved INSIDE the look's own shots directory,
# and the thing it lands on must be a regular file, non-empty, and really under
# that directory once symlinks are resolved. Nothing else is a citation — not a
# quoted line, not an `evidence` word, not a path to somewhere else on the
# machine that happens to exist.
vol_verdict() { # <json-overrides-for-volunteered[0]> <out-verdict>
  "$PY" - "$R/verdict-bare.json" "$1" "$2" <<'VPY'
import json, sys
d = json.load(open(sys.argv[1]))
v = dict(d["volunteered"][0]); v.update(json.loads(sys.argv[2]))
d["volunteered"] = [v]
json.dump(d, open(sys.argv[3], "w"), indent=2)
VPY
}
vol_fate() { # <json-overrides> -> CITED | REFUSED | NEITHER
  local tag p
  tag="$RANDOM$RANDOM"
  vol_verdict "$1" "$R/v-$tag.json" || { printf 'ERR\n'; return; }
  run_score "$SCORE_PY" "$R/v-$tag.json" "$R/s-$tag.json"
  p="$(run_logs "$R/s-$tag.json" "$R/l-$tag")"
  if [ -n "$(vol_rec "$p")" ]; then printf 'CITED\n'
  elif printf '%s\n' "$p" | grep -q "^REFUSED"; then printf 'REFUSED\n'
  else printf 'NEITHER\n'; fi
}

# AND THE WHOLE LIST, NOT ONE ENTRY (fix round 3, FIX 3). `vol_fate` overrides
# fields on a find that already has a title and a saw, so it cannot express an
# entry that says NOTHING — which is the arm that used to drop in silence.
vol_fate_raw() { # <json-array-for-volunteered> -> CITED | REFUSED | NEITHER
  local tag p
  tag="raw$RANDOM$RANDOM"
  "$PY" - "$R/verdict.json" "$1" "$R/v-$tag.json" <<'RPY' || { printf 'ERR\n'; return; }
import json, sys
d = json.load(open(sys.argv[1]))
d["volunteered"] = json.loads(sys.argv[2])
json.dump(d, open(sys.argv[3], "w"), indent=2)
RPY
  run_score "$SCORE_PY" "$R/v-$tag.json" "$R/s-$tag.json"
  p="$(run_logs "$R/s-$tag.json" "$R/l-$tag")"
  if [ -n "$(vol_rec "$p")" ]; then printf 'CITED\n'
  elif printf '%s\n' "$p" | grep -q "^REFUSED"; then printf 'REFUSED\n'
  else printf 'NEITHER\n'; fi
}

row=0
while IFS='|' read -r want js; do
  [ -n "${want:-}" ] || continue
  row=$((row + 1))
  got="$(vol_fate "$js")"
  if [ "$got" = "$want" ]; then
    ok "3k$row. $want — $js"
  else
    bad "3k$row. expected $want, got $got — $js"
  fi
done <<'TBL'
REFUSED|{"title": "The whole app feels slow", "saw": "it felt sluggish"}
REFUSED|{"evidence": "it looked bad"}
CITED|{"shots": ["01-help.txt"]}
REFUSED|{"transcript": "it felt sluggish when I used it"}
REFUSED|{"evidencePath": "n/a"}
REFUSED|{"testQuote": "nothing, I did not run a test"}
REFUSED|{"transcript": "x"}
CITED|{"shot": "02-publish.txt"}
CITED|{"transcriptPath": "02-publish.txt"}
REFUSED|{"testQuote": "FAIL test_readme_lists_publish"}
REFUSED|{"shots": ["no-such-file.png"]}
REFUSED|{"evidencePath": "/tmp/gone-07-footer.txt"}
TBL

# ─── THE THREE CLASSES THAT WALKED THROUGH FIX ROUND 1 (S263 fix round 2) ────
#
# The table above is sound — it was MEASURED discriminating (guard removed: 14
# fails; the round-0 guard restored: 7 fails, exactly the right rows). It was
# just asking a question NEAR the real one, twice. These rows are the real one.
#
# CLASS A — A PATH THAT EXISTS AND IS NOT A RECORD OF THIS LOOK. Rung 1 was
# `os.path.exists(v)` on the raw value, resolved against the PROCESS CWD, with no
# `isfile`, no size and no confinement; rung 2 joined the shots dir without
# normalising, so `..` escaped. Every row here was measured FILING A COMPLETE
# BUG whose AC #1 read ``Recorded in `/etc/passwd` (none).`` and whose real
# `file-logs` argv carried `--attach /etc/passwd`.
#
# CLASS B — A FIELD OF THE WRONG TYPE. `{"shots": 5}` and `shots: true` raised
# `TypeError: \'int\' object is not iterable` out of the filer, which exited 1 and
# wrote nothing — and `xo.sh` read that empty result as "nothing to file" and
# told the captain NOTHING WAS WRONG. A crash must refuse, by name.
#
# CLASS C — PROSE WITH A PATH-SHAPED TOKEN IN IT. The shape test admitted
# `"I looked at config.yaml and it was wrong"` because of the dot, and
# `"the README does not list publish and/or list"` because of the slash. There is
# no rung that reads English any more, so a sentence is simply not a file.
row=0
while IFS='|' read -r want js; do
  [ -n "${want:-}" ] || continue
  row=$((row + 1))
  got="$(vol_fate "$js")"
  if [ "$got" = "$want" ]; then
    ok "3m$row. $want — $js"
  else
    bad "3m$row. expected $want, got $got — $js"
  fi
done <<'TBL2'
REFUSED|{"evidencePath": "/etc/passwd"}
REFUSED|{"evidencePath": "/tmp"}
REFUSED|{"evidencePath": "."}
REFUSED|{"evidencePath": "/"}
REFUSED|{"evidencePath": "sub"}
REFUSED|{"shots": ["sub"]}
REFUSED|{"shots": ["00-empty.txt"]}
REFUSED|{"evidencePath": "00-empty.txt"}
REFUSED|{"transcript": "../outside.txt"}
REFUSED|{"evidencePath": "shots/../outside.txt"}
REFUSED|{"shots": 5}
REFUSED|{"shots": true}
CITED|{"shots": "01-help.txt", "transcript": 7}
REFUSED|{"testQuote": "error: unknown command \"publish\""}
REFUSED|{"testQuote": "Segmentation fault"}
REFUSED|{"testQuote": "Traceback (most recent call last)"}
REFUSED|{"testQuote": "relay list"}
REFUSED|{"testQuote": "$ relay publish --host api.github.com"}
REFUSED|{"transcript": "I looked at config.yaml and it was wrong"}
REFUSED|{"transcript": "the README does not list publish and/or list"}
REFUSED|{"evidencePath": "see https://github.com/x/y for details"}
REFUSED|{"transcript": "and/or"}
CITED|{"transcript": ["01-help.txt"]}
CITED|{"shots": {"a": "01-help.txt"}}
CITED|{"evidencePath": "01-help.txt"}
CITED|{"shots": ["01-help.txt", 5]}
CITED|{"shots": ["sub", "01-help.txt"]}
TBL2

# ─── "INSIDE" MEANS **UNDER** (S263 fix round 3, FIX 2) ──────────────────────
#
# THE MEASURED DEFECT. `vol_record` took every cited name down to its BASENAME
# before resolving it, so a record saved at `deep/a/b/07-footer.txt` under the
# look's own shots directory was looked for at `shots/07-footer.txt`, found
# nothing, and an HONEST find was refused. A reviewer told to save files in a
# directory will make subdirectories in it; a guard that reads only the top of
# that directory throws away exactly the finds it asked for.
#
# AND THE CONTAINMENT GUARANTEE IS NOT WEAKENED ONE INCH. It is still
# `realpath` + `commonpath` on whatever the name lands on, never a string
# prefix — so the three ways out are all still shut, and the LAST row here is
# the one a string prefix would have let through: a SIBLING directory whose name
# starts with the shots directory's own name.
row=0
while IFS='|' read -r want js; do
  [ -n "${want:-}" ] || continue
  row=$((row + 1))
  got="$(vol_fate "$js")"
  if [ "$got" = "$want" ]; then
    ok "3u$row. $want — $js"
  else
    bad "3u$row. expected $want, got $got — $js"
  fi
done <<'TBL3'
CITED|{"shots": ["deep/a/b/07-footer.txt"]}
CITED|{"transcriptPath": "deep/a/b/07-footer.txt"}
CITED|{"shots": ["./deep/a/b/07-footer.txt"]}
CITED|{"shots": ["deep/a/b/07-footer"]}
REFUSED|{"shots": ["deep/a/b/no-such-file.txt"]}
REFUSED|{"shots": ["deep/a/b"]}
REFUSED|{"shots": ["09-link.txt"]}
REFUSED|{"evidencePath": "../outside.txt"}
REFUSED|{"evidencePath": "deep/../../outside.txt"}
REFUSED|{"evidencePath": "../shots-evil/x.txt"}
TBL3
# AND THE RECORD THE LANE EMITS POINTS AT THE DEEP FILE, not at a name that is
# not there: `attach_path` joins the shots dir, so a basenamed deep record would
# hand `xo.sh` `shots/07-footer.txt`, which its own `[ -f ]` drops — the bug
# would arrive with no attachment and a PRD tail that says nothing was recorded.
check "3u-attach. FIX 2 — a record saved UNDER the shots dir is cited and attached where it IS"   'vol_verdict "{\"shots\": [\"deep/a/b/07-footer.txt\"]}" "$R/v-deep.json";
   run_score "$SCORE_PY" "$R/v-deep.json" "$R/s-deep.json";
   rec="$(run_logs "$R/s-deep.json" "$R/l-deep" | vol_rec_stdin)";
   [ -n "$rec" ] &&
   printf "%s" "$rec" | grep -qF "shots/deep/a/b/07-footer.txt" &&
   p="$(printf "%s" "$rec" | cut -d"$RS" -f3)"; [ -f "$p" ] &&
   grep -qF "deep/a/b/07-footer.txt" "$p" &&
   ! grep -qF "outside.txt" "$p"'

# ─── AND AN ENTRY THAT IS DROPPED SAYS SO (S263 fix round 3, FIX 3) ──────────
#
# THE MEASURED DEFECT. `{"saw": 3, "shots": ["01-help.txt"]}` — a find whose only
# words are a non-string scalar — came out of the scorer with the number gone,
# hit the filer's silent `title or saw` filter and VANISHED: FILED=0, REFUSED=0,
# nothing printed, nothing journaled, nothing in `logs.json`. Silence is this
# lane's documented failure mode and the whole reason this session exists. Every
# arm that drops an entry now prints a refusal, and the CONTROLS are the rows
# that must still be CITED (a dict/list `title`/`saw` is recovered by the
# scorer's `_carried_strings` and is NOT this case) and the empty list, which
# must still say nothing at all.
row=0
while IFS='|' read -r want js; do
  [ -n "${want:-}" ] || continue
  row=$((row + 1))
  got="$(vol_fate_raw "$js")"
  if [ "$got" = "$want" ]; then
    ok "3v$row. $want — $js"
  else
    bad "3v$row. expected $want, got $got — $js"
  fi
done <<'TBL4'
REFUSED|[{"saw": 3, "shots": ["01-help.txt"]}]
REFUSED|[{"title": 7, "saw": true, "shots": ["01-help.txt"]}]
REFUSED|[{"shots": ["01-help.txt"]}]
REFUSED|[{}]
REFUSED|["a string, not an object"]
REFUSED|[5]
CITED|[{"title": {"a": "the README documents no command"}, "saw": ["no publish"], "shots": ["01-help.txt"]}]
CITED|[{"title": "t", "saw": "s", "shots": ["01-help.txt"]}]
NEITHER|[]
TBL4
# AND IT IS A REFUSAL, NOT A CRASH, AND IT NAMES WHAT WAS MISSING.
check "3v-words. FIX 3 — the wordless refusal says WHY, and the filer still exits 0"   '"$PY" - "$R/verdict.json" "$R/v-wordless.json" <<PYE
import json, sys
d = json.load(open(sys.argv[1]))
d["volunteered"] = [{"saw": 3, "shots": ["01-help.txt"]}]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYE
   run_score "$SCORE_PY" "$R/v-wordless.json" "$R/s-wordless.json";
   out="$("$PY" "$LOGS_PY" "$R/s-wordless.json" "$R/criteria.json" "$R/l-wordless" \
            "$R/shots" 2>"$R/l-wordless.err")"; rc=$?;
   [ "$rc" = "0" ] && [ ! -s "$R/l-wordless.err" ] &&
   [ "$(printf "%s\n" "$out" | grep -c "^GAP")" = "1" ] &&
   r="$(printf "%s\n" "$out" | grep "^REFUSED")"; [ -n "$r" ] &&
   printf "%s" "$r" | grep -qiE "title|saw" &&
   printf "%s" "$r" | grep -qiE "in words|not a sentence" &&
   printf "%s" "$r" | grep -qiE "nothing was filed"'
# AND IT REFUSES CLEANLY RATHER THAN CRASHING. The rows above would read REFUSED
# even if the filer died, because a dead filer prints nothing — so the exit
# status and the contracted lane are checked directly. MEASURED: `shots: 5` and
# `shots: true` raised `TypeError: 'int'/'bool' object is not iterable`, the
# filer exited 1 and wrote NOTHING, and the contract breach in the same verdict
# was lost with it.
check "3m-exit. THE CURE (D1) — a malformed field refuses cleanly: exit 0, and the contracted bug still files" \
  'vol_verdict "{\"shots\": 5}" "$R/v-bad.json";
   run_score "$SCORE_PY" "$R/v-bad.json" "$R/s-bad.json";
   out="$("$PY" "$LOGS_PY" "$R/s-bad.json" "$R/criteria.json" "$R/l-bad" "$R/shots" 2>"$R/l-bad.err")";
   rc=$?; [ "$rc" = "0" ] &&
   [ "$(printf "%s\n" "$out" | grep -c "^GAP")" = "1" ] &&
   printf "%s\n" "$out" | grep -q "^REFUSED" &&
   ! grep -qi "traceback" "$R/l-bad.err"'
check "3m-score. …and the scorer SANITISES it rather than passing the crash on, like the gaps lane" \
  '"$PY" -c "
import json,sys
v=json.load(open(sys.argv[1]))[\"volunteered\"][0]
assert isinstance(v.get(\"shots\"), list), v
assert all(isinstance(x, str) for x in v[\"shots\"]), v
" "$R/s-bad.json"'
# AND THE REFUSAL IS HONEST ABOUT THE NEW BAR — a human reading it must learn
# that the named thing has to BE THERE, not merely that a field was left blank.
check "3k-why. the refusal says the citation must be a record that EXISTS" \
  'vol_verdict "{\"transcript\": \"it felt sluggish when I used it\"}" "$R/v-why.json";
   run_score "$SCORE_PY" "$R/v-why.json" "$R/s-why.json";
   r="$(run_logs "$R/s-why.json" "$R/l-why" | grep "^REFUSED")";
   printf "%s" "$r" | grep -qiE "exists|on disk|really there|is not there" &&
   printf "%s" "$r" | grep -qi "shot" &&
   printf "%s" "$r" | grep -qi "transcript" &&
   printf "%s" "$r" | grep -qiE "file"'
# AND IT PROMISES WHAT IT ACTUALLY ENFORCES (S263 fix round 2, D2). Fix round 1\'s
# refusal text and the assembled prompt BOTH promised "a real file in the look\'s
# own shots directory" while the rung accepted any path anywhere on the machine.
# Four properties, and the sentence has to name all four, because each one is a
# row that filed a bug: it is a FILE (not a directory), it is NOT EMPTY, it is
# INSIDE the look\'s own shots directory, and it is named as it was SAVED.
check "3k-words. THE CURE — the refusal names all four properties it enforces" \
  'r="$(run_logs "$R/s-why.json" "$R/l-why2" | grep "^REFUSED")";
   printf "%s" "$r" | grep -qiE "shots directory|shots dir" &&
   printf "%s" "$r" | grep -qiE "not a directory|not a folder" &&
   printf "%s" "$r" | grep -qiE "empty|no bytes|0 bytes" &&
   printf "%s" "$r" | grep -qiE "saved it|you saved"'

# THE SHELL MUST NOT SWALLOW IT. `xo.sh` reads these records with a `case` that
# has no default, so a record it does not name is dropped on the floor — which
# is exactly the "a refusal nobody receives measures as nothing" failure.
check "3i. the shell that reads these records HANDLES the refusal rather than dropping it" \
  'grep -q "REFUSED)" "$XO/xo.sh"'
# AND THE LANE FENCE STAYS WHERE IT WAS PUT (S251/S257, lcars-xo-uncontracted 1o3).
check "3j. INVARIANT — the shell still never learns the word volunteered" \
  '! grep -q "volunteered" "$XO/xo.sh"'

# ─── D4: THE THING THAT UNLOCKED THE FILING REACHES THE BUG ─────────────────
#
# MEASURED in fix round 1: a `testQuote`-cited find filed a PRD with NO
# `Recorded in` clause at all — the quote appeared nowhere in the document, so a
# fix worker got six sections of boilerplate with nothing to open or grep. The
# citation and the prose were resolved by TWO different ladders, and they
# disagreed. They are now ONE answer: the record that passed the guard IS the
# record the PRD cites, by construction.
echo ""
echo "3r. D4 — the citation that unlocked the filing is IN the filed bug"

cited_prd() { # <json-overrides> -> prints the PRD path, or ""
  local tag p
  tag="d4$RANDOM"
  vol_verdict "$1" "$R/v-$tag.json" || return 1
  run_score "$SCORE_PY" "$R/v-$tag.json" "$R/s-$tag.json"
  p="$(run_logs "$R/s-$tag.json" "$R/l-$tag" | tr -d '\000')"
  vol_rec "$p" | cut -d"$RS" -f3
}

while IFS= read -r route; do
  [ -n "$route" ] || continue
  PRD="$(cited_prd "$route")"
  check "3r. $route — its PRD names the record that let it in" \
    '[ -n "$PRD" ] && [ -f "$PRD" ] &&
     tr "\n" " " <"$PRD" | grep -q "Recorded in .*01-help.txt" &&
     grep -q "01-help.txt" "$PRD"'
done <<'ROUTES'
{"shots": ["01-help.txt"]}
{"shot": "01-help.txt"}
{"evidencePath": "01-help.txt"}
{"transcriptPath": "01-help.txt"}
{"transcript": ["01-help.txt"]}
{"shots": {"a": "01-help.txt"}}
ROUTES
# AND NOTHING OUTSIDE THE LOOK\'S OWN DIRECTORY IS EVER HUNG ON THE ISSUE. The
# measured consequence of the unconfined rung was a real `file-logs` argv
# carrying `--attach /etc/passwd`, which `log.sh` stages into the mission and
# onto the GitHub issue. Field 7 of the GAP record is that attach list.
check "3r-attach. D2 — every path in the record this lane emits is inside the look\'s shots dir" \
  'vol_verdict "{\"shots\": [\"01-help.txt\"], \"evidencePath\": \"/etc/passwd\", \"transcript\": \"../outside.txt\"}" \
     "$R/v-conf.json";
   run_score "$SCORE_PY" "$R/v-conf.json" "$R/s-conf.json";
   rec="$(run_logs "$R/s-conf.json" "$R/l-conf" | vol_rec_stdin)";
   [ -n "$rec" ] &&
   ! printf "%s" "$rec" | grep -q "/etc/passwd" &&
   ! printf "%s" "$rec" | grep -q "outside.txt" &&
   p="$(printf "%s" "$rec" | cut -d"$RS" -f3)"; [ -f "$p" ] &&
   ! grep -q "/etc/passwd" "$p" && ! grep -q "outside.txt" "$p"'

echo ""
echo "4. LANE 2 — an untested row whose DECLARED cause is the product files"

mk_untested() { # <out> <cause-json-fragment-or-empty>
  "$PY" - "$R/verdict-none.json" "$1" "${2:-}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
row = {"id": "prd-2", "text": "relay publish names the host from the config",
       "impact": "high", "status": "untested",
       "couldNotCheck": "unreachable",
       "note": "there is no publish command in the CLI at all",
       "action": "Ran relay.py --help and read every subcommand."}
if len(sys.argv) > 3 and sys.argv[3]:
    row["cause"] = sys.argv[3]
d["criteria"] = [c for c in d["criteria"] if c["id"] != "prd-2"] + [row]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYEOF
}

mk_untested "$R/v-product.json" product
mk_untested "$R/v-nocause.json" ""
mk_untested "$R/v-rig.json"     rig

for n in product nocause rig; do
  run_score "$SCORE_PY" "$R/v-$n.json" "$R/s-$n.json"
done
PL_PROD="$(run_logs "$R/s-product.json" "$R/l-product")"
PL_NONE="$(run_logs "$R/s-nocause.json" "$R/l-nocause")"
PL_RIG="$(run_logs "$R/s-rig.json" "$R/l-rig")"

has_prd2() { printf '%s\n' "$1" | awk -v RS2="$RS" 'index($0, RS2 "prd-2" RS2)'; }

check "4a. the scorer STAMPS the declared cause onto the ledger row" \
  '"$PY" -c "
import json,sys
e=[r for r in json.load(open(sys.argv[1]))[\"criteria\"] if r[\"id\"]==\"prd-2\"][0]
assert e[\"status\"]==\"untested\", e
assert e.get(\"cause\")==\"product\" and e.get(\"causeRecorded\") is True, e
" "$R/s-product.json"'
check "4b. THE BEHAVIOUR — the blind row whose cause is the PRODUCT is filed as a bug" \
  '[ -n "$(has_prd2 "$PL_PROD")" ]'
check "4c. CONTROL — with NO cause recorded it files nothing, and is read as ours" \
  '[ -z "$(has_prd2 "$PL_NONE")" ] &&
   "$PY" -c "
import json,sys
e=[r for r in json.load(open(sys.argv[1]))[\"criteria\"] if r[\"id\"]==\"prd-2\"][0]
assert e.get(\"causeRecorded\") is False, e
assert \"cause\" not in e, e
" "$R/s-nocause.json"'
check "4d. CONTROL — a cause word nobody recognises (rig) files nothing either" \
  '[ -z "$(has_prd2 "$PL_RIG")" ]'
# RECORD, NEVER INFER — the failure that cost S147, S156 and S188 whole rounds.
check "4e. INVARIANT — the cause is DECLARED, never read out of the note's wording" \
  '"$PY" - "$R/v-nocause.json" "$R/v-prose.json" <<PYE
import json, sys
d = json.load(open(sys.argv[1]))
for c in d["criteria"]:
    if c["id"] == "prd-2":
        c["note"] = ("the product ships no publish command — this is the build, "
                     "not the rig, and the product is at fault")
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYE
   run_score "$SCORE_PY" "$R/v-prose.json" "$R/s-prose.json";
   [ -z "$(has_prd2 "$(run_logs "$R/s-prose.json" "$R/l-prose")")" ]'

echo ""
echo "5. THE INVARIANT — none of this moves the grade"

check "5a. THE BEHAVIOUR — the grade, the recommendation and the blockers are identical with and without" \
  '"$PY" -c "
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
for k in (\"score\",\"recommendation\",\"recommendationWhy\",\"because\",
          \"blockers\",\"followUps\",\"counts\",\"whyThisGrade\",\"scoreMeaning\",
          \"coverageLine\",\"workerScore\",\"derivation\",\"escalations\"):
    assert a.get(k)==b.get(k), (k, a.get(k), b.get(k))
" "$R/scored.json" "$R/scored-none.json"'
# AND ON THE VERDICT WHERE IT WOULD MATTER MOST (S263 fix round 1). 5a measures
# a `medium`/`send-back` verdict, which is already going back — the fence is
# cheapest to hold there. The expensive case is a CLEAN look: every criterion
# met, `high`/`merge`, and a CATASTROPHIC volunteered find beside it. If the lane
# could grade, this is the verdict it would flip. It must not: same grade, same
# recommendation, byte-identical stdout, scored output differing in exactly the
# one carried key. (It was measured as a probe in fix round 1 and kept here, so
# it is a guard and not a memory.)
check "5a2. THE INVARIANT AT ITS MOST EXPENSIVE — a catastrophic find on a high/merge verdict moves nothing" \
  '"$PY" - "$R/verdict.json" "$R/v-clean.json" "$R/v-cat.json" <<PYE
import json, sys
d = json.load(open(sys.argv[1]))
for c in d["criteria"]:
    c["status"] = "met"
    c.pop("sawInstead", None)
d["gaps"] = []
d["score"], d["recommendation"] = "high", "merge"
d["volunteered"] = []
json.dump(d, open(sys.argv[2], "w"), indent=2)
d["volunteered"] = [{"title": "the app deletes every record on start",
                     "expected": "records to survive a restart",
                     "saw": "the store was empty after a restart",
                     "shots": ["01-help.txt"], "evidence": "transcript",
                     "checkedBy": "cli", "impact": "high",
                     "note": "catastrophic, and no criterion covers it"}]
json.dump(d, open(sys.argv[3], "w"), indent=2)
PYE
   "$PY" "$SCORE_PY" "$R/v-clean.json" "$R/criteria.json" "$R/s-clean.json" \
     >"$R/o-clean.txt" 2>&1;
   "$PY" "$SCORE_PY" "$R/v-cat.json" "$R/criteria.json" "$R/s-cat.json" \
     >"$R/o-cat.txt" 2>&1;
   cmp -s "$R/o-clean.txt" "$R/o-cat.txt" &&
   "$PY" -c "
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
assert a.get(\"score\")==b.get(\"score\")==\"high\", (a.get(\"score\"), b.get(\"score\"))
assert a.get(\"recommendation\")==b.get(\"recommendation\")==\"merge\", a.get(\"recommendation\")
diff=sorted(k for k in set(a)|set(b) if a.get(k)!=b.get(k))
assert diff==[\"volunteered\"], diff
" "$R/s-clean.json" "$R/s-cat.json"'

# THE STRONGEST FORM OF IT: the patched scorer and the mutated-out one differ in
# EXACTLY ONE KEY. Anything else the pass-through touched would show up here.
check "5b. the pass-through changed the scored output in EXACTLY ONE key, and that key is volunteered" \
  '"$PY" -c "
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
diff=sorted(k for k in set(a)|set(b) if a.get(k)!=b.get(k))
assert diff==[\"volunteered\"], diff
" "$R/scored.json" "$R/scored-old.json"'
check "5c. …and the volunteered lane is not in the blockers the send-back is decided from" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
for b in d.get(\"blockers\") or []:
    assert not str(b.get(\"id\") or \"\").startswith(\"volunteered-\"), b
" "$R/scored.json"'
check "5d. INVARIANT — xo-criteria.py still never sees the key: it is not a criterion" \
  '! grep -q "volunteered" "$XO/xo-criteria.py"'
# THE STRUCTURAL HALF OF THE SAME FENCE. The scorer may CARRY the key; it may
# not READ it. So exactly one EXECUTABLE line of it is allowed to name the key,
# and that line must be the pass-through — any new reader inside derive_grade,
# derive_recommendation, the coverage floor or a rail fires this.
check "5e. INVARIANT — exactly ONE executable line of the scorer names the key, and it IS the pass-through" \
  'ex="$(grep -n "volunteered" "$SCORE_PY" | grep -v ":[[:space:]]*#")";
   [ "$(printf "%s\n" "$ex" | grep -c .)" = "1" ] &&
   printf "%s" "$ex" | grep -q "S263 PASS-THROUGH"'
check "5f. INVARIANT — the filer still keeps a volunteered bug out of the send-back sentence" \
  'out="$("$PY" "$XO/xo-filed.py" "$R/scored.json" lcars-p \
            prd-1=lcars-kid-1 volunteered-1=lcars-kid-2 2>/dev/null)";
   printf "%s" "$out" | grep -q "lcars-kid-1" &&
     ! printf "%s" "$out" | grep -q "lcars-kid-2"'

# ===========================================================================
# 6. THE ASK — measured on the ASSEMBLED PROMPT, which is where the reviewer
#    actually reads it. evaluate.md alone cannot answer this question: three
#    other suites hold that file UNDER 689 lines and it already sits at the
#    ceiling, so per-round facts go in run.sh (the S248/S249/S251/S261
#    precedent) and the assembled prompt is the only honest surface.
# ===========================================================================
echo ""
echo "6. THE ASK — the assembled prompt names cause, and expects volunteering"

repo="$TMPROOT/repo"; mkdir -p "$repo"
( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'x\n' >"$repo/f.txt"
( cd "$repo" && git add -A && git commit -qm init ) >/dev/null 2>&1
mkdir -p "$repo/.git/lcars/missions/lcars-1/xo"
cat >"$repo/.git/lcars/config.json" <<'CJ'
{"cloneId": "a", "model": "claude-sonnet", "projectName": "r",
 "testCommand": "true", "numberOne": {"enabled": true, "engine": "copilot"},
 "created": "2026-05-30T00:00:00Z"}
CJ
cat >"$repo/.git/lcars/missions/lcars-1/state.json" <<'SJ'
{"id": "lcars-1", "type": "feature", "title": "T", "stage": "verify",
 "branch": "main", "created": "2026-10-04T10:00:00Z"}
SJ
printf '# p\n' >"$repo/.git/lcars/missions/lcars-1/prd.md"

DUMP="$TMPROOT/dump.sh"
cat >"$DUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$DUMP"
WORKER="$TMPROOT/w"; printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKER"; chmod +x "$WORKER"

prompt_for() { # <input-dir> <out-prompt> [mode] [shots-dir] [run.sh]
  ( cd "$repo" && XO_PROMPT_DUMP="$2" LCARS_WORKER_ADAPTER="$DUMP" \
      LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$1" LCARS_GH_BIN=/usr/bin/true \
      LCARS_XO_SHOTS_DIR="${4:-}" LCARS_XO_PROMPTS="$XO/prompts" \
      LCARS_STATE_LIB="$REPO_ROOT/skills/lcars-init/lcars-state.sh" \
      bash "${5:-$RUNSH}" spawn-number-one --mission lcars-1 \
        --mode "${3:-evaluate}" --outdir "$TMPROOT/out-$$-$RANDOM" ) >/dev/null 2>&1
}

IN="$TMPROOT/in"; mkdir -p "$IN"
printf '%s\n' '{"productTypes": [{"type": "cli", "source": "the plan"}],
 "criteria": [{"id": "prd-1", "text": "x"}]}' >"$IN/criteria.json"

# ─── THE ONE SECTION, NOT THE WHOLE PROMPT (S263 fix round 3, FIX 5) ─────────
#
# WHY THIS HELPER EXISTS. Every check in this section used to grep the WHOLE
# assembled prompt — which contains `evaluate.md` as well as the per-round block
# `run.sh` writes. MEASURED on this branch: deleting the ENTIRE `cause` block
# from `run.sh` left 6b, 6c, 6d and 6e GREEN, because `evaluate.md`'s schema line
# says `"cause"`, `product`, `infrastructure`, `FILED as a bug` and `No cause
# recorded` all on its own; only 6b2 discriminated. Reverting the whole
# volunteered paragraph to its pre-S263 permission wording left 6f green, because
# `evaluate.md` says "EXPECTED output" too. That is EXACTLY how round 0's bug
# shipped: a check that cannot fail for its own reason tells a future reader a
# half is covered when it is not.
#
# So each check now measures the SECTION it is about — the `## `-headed block the
# per-round assembler writes — and the mutants below prove each new
# discrimination fires.
section() { # <prompt-file> <heading-substring> -> that `## ` section, or nothing
  "$PY" - "$1" "$2" <<'SEC'
import io, sys
want = sys.argv[2]
out, on = [], False
for ln in io.open(sys.argv[1], encoding="utf-8").read().splitlines():
    if ln.startswith("## "):
        if on:
            break
        on = want in ln
    if on:
        out.append(ln)
sys.stdout.write("\n".join(out) + "\n")
SEC
}
flatten() { tr '\n' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//'; }

# ─── BOTH CONFIGURATIONS, BECAUSE THE ASK IS DIFFERENT IN EACH (FIX 1) ───────
#
# `P`  — NO shots directory: a paper gate, and the honest-inverse ask.
# `PS` — a shots directory and NO WORKTREE: the configuration S263's own ask was
#        unsatisfiable in. `LCARS_XO_WORKTREE` is exported by `xo.sh` only when
#        the disposable copy actually minted, and the shots path was printed ONLY
#        in the camera paragraph, which is gated on that worktree — so a look
#        whose copy failed to mint demanded a file in a directory the prompt
#        named NOWHERE. Measured at 1,106 lines with the path absent entirely.
P="$TMPROOT/prompt.txt"
prompt_for "$IN" "$P"
PSHOTS="$TMPROOT/look-1"; mkdir -p "$PSHOTS"
PS="$TMPROOT/prompt-shots.txt"
prompt_for "$IN" "$PS" evaluate "$PSHOTS"
CAUSE="$(section "$PS" 'WHOSE FAULT IT WAS' | flatten)"
VOL="$(section "$PS" 'NOBODY ASKED FOR' | flatten)"
VOL_NS="$(section "$P" 'NOBODY ASKED FOR' | flatten)"

check "6a. both prompts were captured at all" '[ -s "$P" ] && [ -s "$PS" ]'
check "6a2. …and the two sections this section measures were FOUND, not empty" \
  '[ -n "$CAUSE" ] && [ -n "$VOL" ] && [ -n "$VOL_NS" ] &&
   printf "%s" "$CAUSE" | grep -q "WHOSE FAULT" &&
   printf "%s" "$VOL" | grep -q "NOBODY ASKED FOR"'
check "6b. THE CURE (lane 2) — the per-round block NAMES the cause field" \
  'printf "%s" "$CAUSE" | grep -qF "\"cause\""'
check "6b2. …in the exact JSON FORM, which only the per-round block writes" \
  'printf "%s" "$CAUSE" | grep -qF "\"cause\": \"product\"" &&
   printf "%s" "$CAUSE" | grep -qF "\"cause\": \"infrastructure\""'
check "6c. …and both of its two words, so the reviewer can choose one" \
  'printf "%s" "$CAUSE" | grep -qF "product" &&
   printf "%s" "$CAUSE" | grep -qF "infrastructure"'
check "6d. …and says plainly that a product cause is FILED as a bug" \
  'printf "%s" "$CAUSE" | grep -qiE "cause.{0,200}(FILES IT|filed)"'
check "6e. …and that an untested row with no cause recorded files nothing" \
  'printf "%s" "$CAUSE" | grep -qiE "no recorded .cause.|without a .cause.|leave blank|no cause"'
check "6f. THE CURE (lane 1) — volunteering is framed as EXPECTED OUTPUT, not permission" \
  'printf "%s" "$VOL" | grep -qi "expected output"'
check "6g. …and the prompt says a fault outside the contract left unsaid is a MISS" \
  'printf "%s" "$VOL" | grep -qiE "is a MISS|leaving it unsaid"'
check "6h. …and it tells the reviewer the find must be CITED or it is refused" \
  'printf "%s" "$VOL" | grep -qiE "cited or it is refused|must be cited"'
# AND THE ASK MATCHES THE BAR THE CODE HOLDS (S263 fix round 1, D1). The guard
# refuses a citation that names nothing, so the ask must say so — a guard a
# reviewer cannot satisfy on purpose is a guard that only loses finds.
check "6h2. …and that the citation must be a record that EXISTS, not a filled field" \
  'printf "%s" "$VOL" | grep -qiE "record that EXISTS|really on disk|that is not there cites nothing"'
# AND THE ASK OFFERS EXACTLY THE DOOR THE CODE ENFORCES (S263 fix round 2, D3).
# Round 1's ask invited `testQuote` — "the line as you ran it or as it printed" —
# while its own shape test refused `Segmentation fault` and `error: unknown
# command "publish"`. The route is gone from the code, so the ask must say so
# rather than advertise it, and it must still say what the ONE route is.
check "6h3. THE RESTRUCTURE — the ask names ONE route (a saved file) and says a quoted line is not one" \
  'printf "%s" "$VOL" | grep -qiE "file you saved|a file you saved|save the evidence" &&
   printf "%s" "$VOL" | grep -qiE "shots directory" &&
   printf "%s" "$VOL" | grep -qiE "neither is a quoted line|cannot open and does not accept"'
check "6h4. …and it names the three properties the guard actually checks" \
  'printf "%s" "$VOL" | grep -qiE "not a directory" &&
   printf "%s" "$VOL" | grep -qiE "not empty" &&
   printf "%s" "$VOL" | grep -qiE "inside your shots directory|somewhere else on the machine"'
# ─── FIX 1: THE ASK AND THE ENFORCEMENT CANNOT DISAGREE ──────────────────────
#
# The filer answers against the shots directory it is HANDED (`vol_record`), and
# `xo.sh` hands it the same `$shots` it exports as `LCARS_XO_SHOTS_DIR`. So the
# ask is built from that ONE fact: with a shots directory it NAMES it, on its own
# gate; with none it demands nothing, because nothing can be filed.
check "6l. FIX 1 — with a shots directory and NO WORKTREE, the ask NAMES that directory" \
  'grep -qF "$PSHOTS" "$PS" &&
   printf "%s" "$VOL" | grep -qF "$PSHOTS"'
check "6l2. …and it is named INSIDE the citation ask itself, not only in the camera paragraph" \
  '! grep -qi "Your camera" "$PS" && ! grep -qF "xo-drive.js" "$PS" &&
   printf "%s" "$VOL" | grep -qF "$PSHOTS"'
check "6l3. …and the reviewer is told that directory is its to WRITE records into" \
  'printf "%s" "$VOL" | grep -qiE "yours to write|write records into"'
# THE MEASURED DEFECT, as a check: the only printer of that path was gated on the
# worktree, so this exact configuration named it nowhere.
check "6l4. THE DEFECT — the OLD printer of that path is still silent here (so the ask is its own)" \
  '! printf "%s" "$(section "$PS" "Your camera")" | grep -qF "$PSHOTS"'
check "6m. FIX 1's INVERSE — with NO shots directory the ask demands no file at all" \
  'printf "%s" "$VOL_NS" | grep -qiE "no shots directory" &&
   printf "%s" "$VOL_NS" | grep -qiE "cannot be FILED|can be FILED" &&
   ! printf "%s" "$VOL_NS" | grep -qiE "cited or it is refused"'
check "6m2. …and it still asks for the find, in words, rather than binning it" \
  'printf "%s" "$VOL_NS" | grep -qi "expected output" &&
   printf "%s" "$VOL_NS" | grep -qiE "say it anyway|in words"'
# THE FENCE IS STILL SAID IN THE SAME BREATH. Reframing the lane must not drop
# the sentence that makes it safe to use, or a reviewer reads a licence to grade.
check "6i. INVARIANT — the prompt still says it is never a send-back and moves no score" \
  'printf "%s" "$VOL" | grep -qi "never a send-back" &&
   printf "%s" "$VOL" | grep -qiE "never moves your score" &&
   printf "%s" "$VOL_NS" | grep -qi "never a send-back"'
# AND IT DID NOT GO INTO THE FILE THAT HAS NO ROOM.
check "6j. evaluate.md is still UNDER its 689-line ceiling (three suites hold it there)" \
  '[ "$(grep -c "" "$EVAL_MD")" -lt 689 ]'
check "6k. …and the schema the reviewer copies names cause without costing a line" \
  'grep -qF "\"cause\"" "$EVAL_MD"'

# ===========================================================================
# 6x. THE CONTROLS FOR FIX 5 — each check above now FAILS for its own reason.
#
# Two mutants of `run.sh`, each deleting ONE of the two per-round blocks, with
# `evaluate.md` untouched. For each: the whole assembled prompt STILL contains
# the words the old checks grepped for — that is the vacuity, measured — and the
# SECTION the checks now read is gone, so every one of them fails.
# ===========================================================================
echo ""
echo "6x. FIX 5 — the controls: the discrimination fires"

cut_block() {
  "$PY" - "$1" "$2" "$3" <<'CUT'
import io, sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding="utf-8").read()
i = s.index(a)
j = s.index(b, i) if b else len(s)
out = s[:i] + s[j:]
assert out != s and len(out) < len(s) - 200, (len(s), len(out))
io.open(p, "w", encoding="utf-8").write(out)
CUT
}

# MUTANT 1 — the whole `cause` block deleted from the per-round assembler.
MUT_C="$TMPROOT/mut-cause"
rm -rf "$MUT_C"; cp -R "$REPO_ROOT/skills/lcars-run" "$MUT_C" >/dev/null 2>&1
cut_block "$MUT_C/run.sh" '
## WHOSE FAULT IT WAS WHEN YOU COULD NOT CHECK' 'row you write."'
PMC="$TMPROOT/prompt-mut-cause.txt"
prompt_for "$IN" "$PMC" evaluate "$PSHOTS" "$MUT_C/run.sh"
MC_CAUSE="$(section "$PMC" 'WHOSE FAULT IT WAS' | flatten)"
check "6x1. fixture — the cause-block mutant still assembles a prompt" \
  '[ -s "$PMC" ] && bash -n "$MUT_C/run.sh"'
check "6x2. THE VACUITY, MEASURED — the mutant prompt STILL says cause/product/filed" \
  'f="$(tr "\n" " " <"$PMC" | tr -s " ")";
   printf "%s" "$f" | grep -qF "\"cause\"" &&
   printf "%s" "$f" | grep -qF "infrastructure" &&
   printf "%s" "$f" | grep -qiE "cause.{0,200}(FILES IT|filed)" &&
   printf "%s" "$f" | grep -qiE "no recorded .cause.|no cause"'
check "6x3. THE DISCRIMINATION — 6b/6c/6d/6e all FAIL on it, because the block is gone" \
  '[ -z "$MC_CAUSE" ] &&
   ! printf "%s" "$MC_CAUSE" | grep -qF "\"cause\"" &&
   ! printf "%s" "$MC_CAUSE" | grep -qF "infrastructure" &&
   ! printf "%s" "$MC_CAUSE" | grep -qiE "cause.{0,200}(FILES IT|filed)" &&
   ! printf "%s" "$MC_CAUSE" | grep -qiE "no recorded .cause.|no cause"'

# MUTANT 2 — the whole volunteered paragraph deleted from the per-round
# assembler, which is what "reverted to its pre-S263 permission wording" leaves
# behind as far as these words go: `evaluate.md` still says EXPECTED output.
MUT_V="$TMPROOT/mut-vol"
rm -rf "$MUT_V"; cp -R "$REPO_ROOT/skills/lcars-run" "$MUT_V" >/dev/null 2>&1
cut_block "$MUT_V/run.sh" '
## Something wrong that NOBODY ASKED FOR' '
## WHOSE FAULT IT WAS WHEN YOU COULD NOT CHECK'
PMV="$TMPROOT/prompt-mut-vol.txt"
prompt_for "$IN" "$PMV" evaluate "$PSHOTS" "$MUT_V/run.sh"
MV_VOL="$(section "$PMV" 'NOBODY ASKED FOR' | flatten)"
check "6x4. fixture — the volunteered-block mutant still assembles a prompt" \
  '[ -s "$PMV" ] && bash -n "$MUT_V/run.sh"'
check "6x5. THE VACUITY, MEASURED — the mutant prompt STILL says EXPECTED output" \
  'f="$(tr "\n" " " <"$PMV" | tr -s " ")";
   printf "%s" "$f" | grep -qi "expected output" &&
   printf "%s" "$f" | grep -qi "volunteered"'
check "6x6. THE DISCRIMINATION — 6f/6g/6h/6h2/6h3/6h4 and 6l all FAIL on it" \
  '[ -z "$MV_VOL" ] &&
   ! printf "%s" "$MV_VOL" | grep -qi "expected output" &&
   ! printf "%s" "$MV_VOL" | grep -qiE "is a MISS|leaving it unsaid" &&
   ! printf "%s" "$MV_VOL" | grep -qiE "cited or it is refused|must be cited" &&
   ! printf "%s" "$MV_VOL" | grep -qiE "record that EXISTS" &&
   ! printf "%s" "$MV_VOL" | grep -qF "$PSHOTS"'
# AND THE SHOTS PATH IS THE ASK'S OWN, NOT THE CAMERA'S: with the volunteered
# block cut, nothing in this (worktree-less) prompt names the directory at all —
# which is precisely the state FIX 1 found and cured.
check "6x7. …and with it cut, the worktree-less prompt names the shots directory NOWHERE" \
  '! grep -qF "$PSHOTS" "$PMV"'

# ===========================================================================
# 8. THROUGH THE REAL SHELL — a refusal that LASTS, and a crash that is never
#    read as a clean bill of health. Driven through the real `file-logs` verb
#    (the `tests/lcars-xo-refusal.test.sh` rig), because both defects are at the
#    CALL SITE and no amount of testing the filer alone can see them.
# ===========================================================================
echo ""
echo "8. THE SHELL — a durable refusal, and a crash that does not read as clean"

E2E="$TMPROOT/e2e"; mkdir -p "$E2E"
LOGSTUB="$E2E/log-ok.sh"
cat >"$LOGSTUB" <<'LGS'
#!/usr/bin/env bash
parent=""; n=0; args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --parent) parent="${args[$((i+1))]}"; i=$((i+2)) ;;
    --prd)    n=$((n+1)); i=$((i+2)) ;;
    *)        i=$((i+1)) ;;
  esac
done
md="$PWD/.git/lcars/missions"
j=1
while [ "$j" -le "$n" ]; do
  kid="lcars-20261009-80$j-bbbb"
  mkdir -p "$md/$kid"
  printf '{"id": "%s", "stage": "plan", "parent": "%s"}\n' "$kid" "$parent" >"$md/$kid/state.json"
  printf '  %s  #%d  a filed bug\n' "$kid" "$((600 + j))"
  j=$((j + 1))
done
exit 0
LGS
chmod +x "$LOGSTUB"
printf '#!/usr/bin/env bash\nexit 0\n' >"$E2E/stub"; chmod +x "$E2E/stub"

e2e_repo() { # <name> <scored-verdict> -> prints the mission dir
  local repo="$E2E/$1" m="lcars-20261009-700"
  rm -rf "$repo"; mkdir -p "$repo"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/$m/xo/shots"
  cat >"$repo/.git/lcars/config.json" <<'CJ'
{"cloneId": "aaaaaaaa", "projectName": "repo", "testCommand": "true",
 "created": "2026-05-30T00:00:00Z",
 "numberOne": {"enabled": true, "engine": "copilot", "filesBugs": true}}
CJ
  # ONE FIELD PER LINE — `state_set_xo` refuses anything else and leaves the
  # mission untouched, which would make every check below pass for the wrong
  # reason.
  cat >"$repo/.git/lcars/missions/$m/state.json" <<SJ
{
  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-10-09T10:00:00Z"},
  "id": "$m",
  "type": "feature",
  "title": "The relay CLI",
  "stage": "verify",
  "branch": "main",
  "created": "2026-10-09T10:00:00Z",
  "githubIssue": 42
}
SJ
  cp "$R/criteria.json" "$repo/.git/lcars/missions/$m/xo/criteria.json"
  cp "$2"               "$repo/.git/lcars/missions/$m/xo/verdict.json"
  cp "$R/shots/01-help.txt" "$repo/.git/lcars/missions/$m/xo/shots/"
  printf '%s' "$repo/.git/lcars/missions/$m"
}

drive_file_logs() { # <repo-root> <xo.sh to run>
  ( cd "$1" && LCARS_LOG_SCRIPT="$LOGSTUB" LCARS_RESOLVE_LOGS_SCRIPT="$E2E/stub" \
      LCARS_RUN_SCRIPT=/usr/bin/true LCARS_HOST_ADAPTER="$E2E/stub" \
      LCARS_GH_BIN=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      bash "$2" file-logs --mission lcars-20261009-700 2>&1 )
}

# --- D5: A REFUSAL REACHES A DURABLE SURFACE --------------------------------
# MEASURED in fix round 1: the refusal printed to the run log and reached NOTHING
# else — not `xo/logs.json`, not `number-one.jsonl`, and `xo-report.py` never
# mentioned the lane at all. The captain reads phone readouts from an unattended
# run hours later, so a refusal he cannot see later is a refusal that did not
# happen. `number-one.jsonl` is the surface `xo-report.py` already renders every
# entry of, so journaling it puts it on the report with no report change at all.
"$PY" - "$R/verdict.json" "$E2E/v-refused.json" <<'PYE'
import json, sys
d = json.load(open(sys.argv[1]))
d["volunteered"] = [{"title": "the whole app feels slow",
                     "saw": "it felt sluggish", "evidence": "transcript"}]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYE
run_score "$SCORE_PY" "$E2E/v-refused.json" "$E2E/s-refused.json"
M_REF="$(e2e_repo refused "$E2E/s-refused.json")"
OUT_REF="$(drive_file_logs "${M_REF%/.git/lcars/missions/*}" "$XO/xo.sh")"

check "8a. the real verb still filed the CONTRACTED bug (the rig works)" \
  'printf "%s\n" "$OUT_REF" | grep -qi "filed 1 mission log"'
check "8b. …and said the uncited find was not filed, where the captain can see it" \
  'printf "%s\n" "$OUT_REF" | grep -qi "not filed" &&
   printf "%s\n" "$OUT_REF" | grep -qi "feels slow"'
check "8c. THE CURE (D5) — the refusal is in the mission journal, durably" \
  '[ -s "$M_REF/number-one.jsonl" ] &&
   grep -q "feels slow" "$M_REF/number-one.jsonl"'
check "8d. …and in xo/logs.json, the record the surfaces read" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
r=d.get(\"refused\") or []
assert r and isinstance(r, list), d
assert any(\"feels slow\" in str(x.get(\"what\")) for x in r), r
assert all(str(x.get(\"why\") or \"\").strip() for x in r), r
" "$M_REF/xo/logs.json"'
check "8e. …and xo-report.py renders that journal entry rather than dropping it" \
  'out="$("$PY" "$XO/xo-report.py" "${M_REF%/*}" "$E2E/seen.json" --all 2>/dev/null)";
   printf "%s" "$out" | grep -qi "not filed" &&
   printf "%s" "$out" | grep -qi "feels slow"'
check "8f. INVARIANT — the shell STILL never learns the word volunteered" \
  '! grep -q "volunteered" "$XO/xo.sh"'

# --- D1(2): A CRASH IS NEVER REPORTED AS A CLEAN BILL OF HEALTH -------------
# MEASURED: `plan="$(… 2>/dev/null)" || plan=""` discarded the traceback, and an
# empty result read as "nothing to file". The captain was told `nothing on <id>
# contradicts what you wrote down — no logs filed.` with a durable journal line
# `{"action":"filed-logs","filed":0,"detail":"no contradictions to file"}` — and
# any genuine contract breach in the same run went with it. A crash became a
# clean bill of health.
# A SKILL TREE THAT IS THE REAL ONE EXCEPT FOR THE FILER. `xo.sh` sources
# `../lcars-init/lcars-common.sh`, so the copy has to sit beside its siblings;
# every other skill dir is symlinked and only `lcars-xo` is a real copy.
mkdir -p "$E2E/skills"
for d in "$REPO_ROOT"/skills/*/; do
  ln -sfn "$d" "$E2E/skills/$(basename "$d")"
done
BROKE="$E2E/skills/lcars-xo"; rm -f "$BROKE"; rm -rf "$E2E/skills/lcars-xo.real"
cp -R "$XO" "$BROKE"
rm -rf "$BROKE/__pycache__"
printf 'import sys\nsys.stderr.write("boom\\n")\nsys.exit(1)\n' >"$BROKE/xo-logs.py"
M_BROKE="$(e2e_repo broken "$R/scored.json")"
OUT_BROKE="$(drive_file_logs "${M_BROKE%/.git/lcars/missions/*}" "$BROKE/xo.sh")"
check "8g0. fixture — the stand-in skill tree ran at all (its siblings resolved)" \
  '! printf "%s\\n" "$OUT_BROKE" | grep -q "shared library is missing"'

check "8g. fixture — the stand-in filer really does exit non-zero" \
  '! "$PY" "$BROKE/xo-logs.py" >/dev/null 2>&1'
check "8h. THE CURE (D1) — a filer that failed is NOT reported as nothing being wrong" \
  '! printf "%s\n" "$OUT_BROKE" | grep -qi "contradicts what you wrote down"'
check "8i. …it says the filer FAILED, in words the captain can act on" \
  'printf "%s\n" "$OUT_BROKE" | grep -qiE "could not|failed" &&
   printf "%s\n" "$OUT_BROKE" | grep -qiE "nothing was filed|no logs filed"'
check "8j. …and the durable journal line does not claim there was nothing to file" \
  '[ -s "$M_BROKE/number-one.jsonl" ] &&
   ! grep -q "no contradictions to file" "$M_BROKE/number-one.jsonl" &&
   grep -qE "could not|failed" "$M_BROKE/number-one.jsonl"'
# THE CONTROL — without it, 8h/8i cannot tell "the crash is reported" from "the
# all-clear sentence was deleted". A verdict with NOTHING to file must still
# print it.
"$PY" - "$R/verdict.json" "$E2E/v-clear.json" <<'PYE'
import json, sys
d = json.load(open(sys.argv[1]))
for c in d["criteria"]:
    c["status"] = "met"; c.pop("sawInstead", None)
d["gaps"] = []; d["volunteered"] = []
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYE
run_score "$SCORE_PY" "$E2E/v-clear.json" "$E2E/s-clear.json"
M_CLEAR="$(e2e_repo clear "$E2E/s-clear.json")"
OUT_CLEAR="$(drive_file_logs "${M_CLEAR%/.git/lcars/missions/*}" "$XO/xo.sh")"
check "8k. CONTROL — a genuinely clean look still gets the all-clear sentence" \
  'printf "%s\n" "$OUT_CLEAR" | grep -qi "contradicts what you wrote down" &&
   grep -q "no contradictions to file" "$M_CLEAR/number-one.jsonl"'

# ===========================================================================
# 9. A SCORER THAT DIED IS NOT A GRADE (S263 fix round 3, FIX 4)
#
# `xo.sh`'s scorer call site was `report="$(… xo-score.py … 2>/dev/null)" ||
# report=""` — the EXACT pattern S263 cured on the filer in section 8. The exit
# status went in the bin with the traceback, so a scorer that CRASHED was
# indistinguishable from a scorer that said nothing, and the empty result fell
# through to an arm that blames the VERDICT ("I could not read back my own
# verdict") for a fault in OUR code. Worse: a scorer that dies after printing its
# wire lines leaves `$score` set while `xo/verdict.json` was never rewritten — so
# a mission with an EARLIER look would be finished and FILED against a STALE
# verdict.
#
# Driven through the REAL `evaluate` verb, because the defect is at the call site
# and nothing that tests the scorer alone can see it. The underlying crash (a
# malformed `gaps[].shots` raising inside `xo-score.py`) is DELIBERATELY not
# fixed here — it is ledgered for the captain — so the fixture is a scorer that
# exits non-zero, which is what the crash does.
# ===========================================================================
echo ""
echo "9. THE SCORER — a crash is reported as a crash, and files nothing"

EV="$TMPROOT/ev"; mkdir -p "$EV"
export XO_LAUNCH_LOG="$EV/launch.log"; : >"$XO_LAUNCH_LOG"
cat >"$EV/launch.sh" <<'LS'
#!/usr/bin/env bash
mid="$1"; shift
m="$PWD/.git/lcars/missions/$mid"
printf 'launch %s %s\n' "$mid" "$*" >>"$XO_LAUNCH_LOG"
case "${1:-}" in
  --stop) printf '{\n  "status": "stopped"\n}\n' >"$m/launch.json"; exit 0 ;;
esac
printf '{\n  "status": "running",\n  "url": "http://127.0.0.1:4310/",\n  "pid": 1\n}\n' >"$m/launch.json"
LS
chmod +x "$EV/launch.sh"
cat >"$EV/drive.sh" <<'DS'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"
printf 'PNG\n' >"$out/shot-01.png"
printf '{"shot":"shot-01"}\n' >"$out/shot-01.json"
printf '{"url":"http://127.0.0.1:4310/","allPainted":true}\n'
exit 0
DS
chmod +x "$EV/drive.sh"
# THE WORKER WRITES THE VERDICT THE RIG ALREADY USES — one contracted gap, so a
# look that reaches its grade has something to FILE and the control is real.
cp "$R/verdict.json" "$EV/say.json"
cat >"$EV/worker" <<'EVW'
#!/usr/bin/env bash
[ -n "${LCARS_WORK_OUT:-}" ] && cp "$EV_SAY" "$LCARS_WORK_OUT/xo-verdict.json"
exit 0
EVW
chmod +x "$EV/worker"

ev_repo() { # <name> -> prints the mission dir
  local repo="$EV/$1" m="lcars-20261009-900"
  rm -rf "$repo"; mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/$m/xo"
  cat >"$repo/.git/lcars/config.json" <<'CJ'
{"cloneId": "aaaaaaaa", "projectName": "repo", "testCommand": "true",
 "created": "2026-05-30T00:00:00Z",
 "numberOne": {"enabled": true, "engine": "copilot", "filesBugs": true}}
CJ
  cat >"$repo/.git/lcars/missions/$m/state.json" <<SJ
{
  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-10-09T10:00:00Z"},
  "id": "$m",
  "type": "feature",
  "title": "The relay CLI",
  "stage": "verify",
  "branch": "main",
  "created": "2026-10-09T10:00:00Z",
  "githubIssue": 42
}
SJ
  printf '# The relay CLI\n\n## Acceptance criteria\n- prd-1: relay file stores the title it was given\n' \
    >"$repo/.git/lcars/missions/$m/prd.md"
  printf '%s\n' '{"tickets": [{"id": "t-1", "acceptanceCriteria": [{"text": "relay file stores the title it was given", "serves": "prd-1", "kind": "works", "notVisual": true, "direction": "delivers"}]}]}' \
    >"$repo/.git/lcars/missions/$m/plan.json"
  printf '%s' "$repo/.git/lcars/missions/$m"
}

drive_evaluate() { # <repo-root> <xo.sh to run>
  "$PY" "$TESTS_CAGE" 420 bash -c '
    cd "$1" && EV_SAY="$2" LCARS_LAUNCH_SCRIPT="$3" LCARS_XO_DRIVER="$4" \
      LCARS_NODE_BIN=bash LCARS_WORKER_BIN="$5" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_LOG_SCRIPT="$7" LCARS_RESOLVE_LOGS_SCRIPT=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 LCARS_XO_UNLISTED=0 LCARS_XO_PRELAUNCH=0 \
      bash "$6" evaluate --mission lcars-20261009-900 2>&1' _ \
    "$1" "$EV/say.json" "$EV/launch.sh" "$EV/drive.sh" "$EV/worker" "$2" "$LOGSTUB"
}
TESTS_CAGE="$REPO_ROOT/tests/lib/cage.py"

# A SKILL TREE THAT IS THE REAL ONE EXCEPT FOR THE SCORER — the same stand-in
# trick section 8 uses for the filer, because `xo.sh` sources its siblings.
mkdir -p "$EV/skills"
for d in "$REPO_ROOT"/skills/*/; do
  ln -sfn "$d" "$EV/skills/$(basename "$d")"
done
BROKE_S="$EV/skills/lcars-xo"; rm -f "$BROKE_S"; cp -R "$XO" "$BROKE_S"
rm -rf "$BROKE_S/__pycache__"
printf 'import sys\nsys.stderr.write("boom\\n")\nsys.exit(1)\n' >"$BROKE_S/xo-score.py"

M_SBROKE="$(ev_repo score-broken)"
# AND AN EARLIER LOOK'S VERDICT IS SITTING THERE. This is the expensive half of
# the defect: a scorer that dies leaves `xo/verdict.json` unwritten, so on a
# mission that has been looked at before, the run could be finished and FILED
# against a STALE verdict — a previous grade reported as this look's.
printf '%s\n' '{"score": "high", "recommendation": "merge", "criteria": [],
 "gaps": [], "summary": "STALE-MARKER from an earlier look"}' \
  >"$M_SBROKE/xo/verdict.json"
OUT_SBROKE="$(drive_evaluate "${M_SBROKE%/.git/lcars/missions/*}" "$BROKE_S/xo.sh")"
printf '  what the captain is told when the scorer dies:\n'
printf '%s\n' "$OUT_SBROKE" | grep -n "NUMBER ONE\|clean bill\|Look yourself\|look yourself" | sed 's/^/    /'
check "9a. fixture — the stand-in scorer really does exit non-zero" \
  '! "$PY" "$BROKE_S/xo-score.py" >/dev/null 2>&1'
check "9a2. fixture — the look RAN: a worker verdict was taken and a grade was attempted" \
  'printf "%s\n" "$OUT_SBROKE" | grep -qiE "looking|round|verdict|Number One"'
check "9b. THE CURE (FIX 4) — it says MY OWN SCORER FAILED, with the exit status" \
  'printf "%s\n" "$OUT_SBROKE" | grep -qiE "could not score" &&
   printf "%s\n" "$OUT_SBROKE" | grep -qiE "scorer failed" &&
   printf "%s\n" "$OUT_SBROKE" | grep -qE "exit [1-9]"'
# FLATTENED, because the sentence WRAPS across two printf lines — a check that
# greps the unwrapped form measures the line width and not the sentence.
check "9c. …and says plainly that this is NOT a clean bill of health" \
  'printf "%s\n" "$OUT_SBROKE" | tr "\n" " " | tr -s " " |
     grep -qi "not a clean bill of health"'
check "9d. …and it does not blame the VERDICT for a fault in our own code" \
  '! printf "%s\n" "$OUT_SBROKE" | grep -qi "contradicts what you wrote down"'
check "9e. …and the crash is in the mission journal, durably" \
  '[ -s "$M_SBROKE/number-one.jsonl" ] &&
   grep -q "score-failed" "$M_SBROKE/number-one.jsonl" &&
   grep -qE "scorer failed" "$M_SBROKE/number-one.jsonl"'
check "9f2. …and the STALE verdict from the earlier look is neither kept nor filed" \
  '[ -s "$M_SBROKE/xo/verdict.json" ] &&
   ! grep -q "STALE-MARKER" "$M_SBROKE/xo/verdict.json" &&
   "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"score\") == \"low\", d.get(\"score\")
" "$M_SBROKE/xo/verdict.json"'
check "9f. …and NOTHING was filed from it: no bug mission, no logs.json" \
  '[ ! -f "$M_SBROKE/xo/logs.json" ] &&
   [ -z "$(ls -d "${M_SBROKE%/*}"/lcars-20261009-80* 2>/dev/null)" ]'
# THE CONTROL — without it, 9b/9d cannot tell "a crash is reported" from "this
# rig never reaches the scorer at all". The SAME rig with the REAL scorer must
# grade the look and file the contracted bug.
M_SOK="$(ev_repo score-ok)"
OUT_SOK="$(drive_evaluate "${M_SOK%/.git/lcars/missions/*}" "$XO/xo.sh")"
check "9g. CONTROL — the same rig with the REAL scorer reaches a grade" \
  '! printf "%s\n" "$OUT_SOK" | grep -qiE "could not score|scorer failed" &&
   [ -s "$M_SOK/xo/verdict.json" ] &&
   "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"score\") in (\"low\",\"medium\",\"high\"), d.get(\"score\")
" "$M_SOK/xo/verdict.json"'
check "9h. CONTROL — …and it FILES the contracted bug, which the crash run did not" \
  'printf "%s\n" "$OUT_SOK" | grep -qiE "filed 1 mission log|mission log" &&
   [ -s "$M_SOK/xo/logs.json" ]'

echo ""
echo "7. ZERO SPEND"
calls="$(wc -l <"$SPEND_LOG" | tr -d " ")"
models="$(grep -c -- '--model' "$SPEND_LOG" || true)"; models="${models:-0}"
printf '  shim invocations: %s (with --model: %s)\n' "$calls" "$models"
check "7a. no engine was ever invoked — this suite costs nothing" '[ "$calls" = "0" ]'

echo ""
printf 'lcars-xo-volunteered: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
