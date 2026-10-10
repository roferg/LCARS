#!/usr/bin/env bash
# tests/lcars-xo-near-miss.test.sh — S258.
#
# WHAT WAS MEASURED, AND WHAT WAS NOT. The four prompt files already tell the
# reviewer to OPERATE the product: `evaluate.md` says "move the way a person
# does: `click`, `type`", requires a record of which control was clicked, and
# states that only an ACTION can settle a `works` criterion. So nothing here
# adds an operate-it clause — that would be adding what is there and claiming
# it. What was genuinely absent is the NEGATIVE half: `near miss` / `near-miss`
# had ZERO hits across all four files, and play/game appeared only as examples
# of judgement, never as an instruction to take a rules-driven thing through the
# paths its own rules say must REFUSE or LOSE. One fault (G2 of nine planted) has
# never been found by anybody, and it is the one that can only be reached that
# way: every reviewer verified the rule by SATISFYING it.
#
# So:
#   1. THE NEGATIVE-RULE CLAUSE — a stated rule is verified by BREAKING it; try
#      the input that is almost right and must be refused; reach an ending the
#      rules call a loss or a refusal. It NAMES NO FAULT: a clause that names a
#      plant proves nothing, so the forbidden words are asserted ABSENT from the
#      clause itself (`repeat`, `permutation`, `score`, `reset`, `limit`).
#   2. THE VOLUNTEERED LANE IS OFFERED IN THE SAME BREATH — breaking a rule is
#      how you meet a fault nobody wrote a criterion for. Prompt text only: the
#      lane stays structurally unable to move the grade, and `xo-score.py` must
#      never learn the word (re-asserted below; owned by lcars-xo-uncontracted).
#
# AND IT IS ASSERTED ON THE ASSEMBLED PROMPT, NOT THE TEMPLATE. The claim that
# "the checklists never reach Number One" came from grepping a template; the
# seam is `run.sh spawn-number-one` → `spawn_number_one` → `spawn_worker`, whose
# $5 to the worker adapter IS the prompt the worker is handed. A stub adapter
# dumps that argument. Every assertion is paired with a MUTATION — the same
# assembled-prompt check against a prompts dir with the clause stripped (or with
# a forbidden word injected) — which must FAIL, so none of them can pass
# vacuously.
#
# ZERO SPEND: a PATH shim fakes both engines and counts every call; the count is
# asserted at the end.
#
# Usage: bash tests/lcars-xo-near-miss.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
PROMPTS="$REPO_ROOT/skills/lcars-xo/prompts"
SCORE_PY="$REPO_ROOT/skills/lcars-xo/xo-score.py"
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
printf '%s %s\n' "$eng" "\$*" >>"\$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"

# --- the repo the prompt is assembled in -----------------------------------
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
 "branch": "main", "created": "2026-10-06T10:00:00Z"}
SJ
printf '# p\n' >"$repo/.git/lcars/missions/lcars-1/prd.md"

IN="$TMPROOT/in"; mkdir -p "$IN"
criteria_for() { # <product-type>
  printf '%s\n' "{\"productTypes\": [{\"type\": \"$1\", \"source\": \"the plan\"}],
 \"criteria\": [{\"id\": \"prd-1\", \"text\": \"x\"}]}" >"$IN/criteria.json"
}
criteria_for cli

# --- THE SEAM: the adapter is handed the assembled prompt as $5 -------------
DUMP="$TMPROOT/dump.sh"
cat >"$DUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$DUMP"
WORKER="$TMPROOT/w"; printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKER"; chmod +x "$WORKER"

prompt_for() { # <out-prompt> <mode> [prompts-dir]
  ( cd "$repo" && XO_PROMPT_DUMP="$1" LCARS_WORKER_ADAPTER="$DUMP" \
      LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
      LCARS_XO_PROMPTS="${3:-$PROMPTS}" \
      bash "$RUNSH" spawn-number-one --mission lcars-1 \
        --mode "$2" --outdir "$TMPROOT/out-$$-$RANDOM" ) >/dev/null 2>&1
}

# A mutated copy of the prompts dir: every line of the clause GONE. Each
# assertion below is run against this too, where it must FAIL — that is the
# proof none of them is passing on something that was already in the file.
mutate() { # <dir> <python-mutation-of-the-text>
  local d="$1" expr="$2" f
  mkdir -p "$d"
  cp "$PROMPTS"/*.md "$d"/
  for f in evaluate.md recheck.md; do
    "$PY" - "$d/$f" "$expr" <<'PYM'
import re, sys
p, mode = sys.argv[1], sys.argv[2]
text = open(p, encoding="utf-8").read()
paras = text.split("\n\n")
anchor = "a rule you only ever"
anchor2 = "rule's fix is held only when"
keep = []
for para in paras:
    low = para.lower()
    if mode == "strip" and (anchor in low or anchor2 in low):
        continue
    if mode == "inject" and (anchor in low or anchor2 in low):
        para = para + " The score must reset to zero."
    keep.append(para)
open(p, "w", encoding="utf-8").write("\n\n".join(keep))
PYM
  done
}

STRIPPED="$TMPROOT/prompts-stripped"; mutate "$STRIPPED" strip
INJECTED="$TMPROOT/prompts-injected"; mutate "$INJECTED" inject

P_EV="$TMPROOT/prompt-evaluate.txt";       prompt_for "$P_EV" evaluate
P_RE="$TMPROOT/prompt-recheck.txt";        prompt_for "$P_RE" recheck
P_EV_S="$TMPROOT/prompt-evaluate-str.txt"; prompt_for "$P_EV_S" evaluate "$STRIPPED"
P_RE_S="$TMPROOT/prompt-recheck-str.txt";  prompt_for "$P_RE_S" recheck "$STRIPPED"
P_EV_I="$TMPROOT/prompt-evaluate-inj.txt"; prompt_for "$P_EV_I" evaluate "$INJECTED"
P_WEB="$TMPROOT/prompt-web.txt";         criteria_for web; prompt_for "$P_WEB" evaluate
P_WORK="$TMPROOT/prompt-workflow.txt";   criteria_for workflow; prompt_for "$P_WORK" evaluate
criteria_for cli

# `tr` the newlines away first: the prompt files wrap at ~78 columns, so every
# phrase worth asserting on is split across lines in the artefact.
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }
says() { flat "$1" | grep -qi -- "$2"; }
occurs() { flat "$1" | grep -oEi -- "$2" | wc -l | tr -d ' '; }

echo "1. THE ASSEMBLED PROMPT — captured at the seam, not read off a template"
check "1a. the evaluate prompt was captured at all" '[ -s "$P_EV" ]'
check "1b. the recheck prompt was captured at all" '[ -s "$P_RE" ]'
check "1c. it IS the assembled artefact — it carries the template AND the round's own block" \
  'says "$P_EV" "You are Number One" && says "$P_EV" "## The mission" &&
   says "$P_EV" "Your output file"'
check "1d. CONTROL — the mutation harness really did reach the same seam" \
  '[ -s "$P_EV_S" ] && [ -s "$P_RE_S" ]'

echo ""
echo "2. THE NEGATIVE-RULE CLAUSE reaches the worker"
check "2a. a rule you only ever satisfied is a rule you have not tested" \
  'says "$P_EV" "a rule you only ever satisfied is a rule you have not tested"'
check "2b. MUTATION — that assertion fails with the clause stripped" \
  '! says "$P_EV_S" "a rule you only ever satisfied is a rule you have not tested"'
check "2c. a stated rule is verified by BREAKING it" \
  'says "$P_EV" "verified by breaking it"'
check "2d. MUTATION — that assertion fails with the clause stripped" \
  '! says "$P_EV_S" "verified by breaking it"'
check "2e. the input that is ALMOST right and must be refused" \
  'says "$P_EV" "almost right and must be refused"'
check "2e2. …and the thing it is asking for is NAMED — the near miss" \
  'says "$P_EV" "ask for the near miss" && says "$P_RE" "but the near miss turned away"'
check "2e3. MUTATION — stripping the clause removes one named near miss" \
  '[ "$(occurs "$P_EV" "near.miss")" -gt "$(occurs "$P_EV_S" "near.miss")" ] &&
   [ "$(occurs "$P_RE" "near.miss")" -gt "$(occurs "$P_RE_S" "near.miss")" ]'
check "2f. MUTATION — that assertion fails with the clause stripped" \
  '! says "$P_EV_S" "almost right and must be refused"'
check "2g. …and what happened is RECORDED whichever way it went" \
  'says "$P_EV" "record what happened either way"'
check "2h. MUTATION — stripping the clause removes one recording instruction" \
  '[ "$(occurs "$P_EV" "record what happened either way")" -gt "$(occurs "$P_EV_S" "record what happened either way")" ]'
check "2i. a refusal that never came is a gap; one you never asked for is untested" \
  'says "$P_EV" "a refusal that never came is a gap" && says "$P_EV" "is .untested."'
check "2j. MUTATION — that assertion fails with the clause stripped" \
  '! says "$P_EV_S" "a refusal that never came is a gap"'
check "2k. THE OTHER HALF — reach an ending the rules call a LOSS or a REFUSAL" \
  'says "$P_EV" "a loss or a refusal"'
check "2l. …and not only the winning one" \
  'says "$P_EV" "not only the winning one"'
check "2m. MUTATION — stripping the clause removes one copy of both instructions" \
  '[ "$(occurs "$P_EV" "a loss or a refusal")" -gt "$(occurs "$P_EV_S" "a loss or a refusal")" ] &&
   [ "$(occurs "$P_EV" "not only the winning one")" -gt "$(occurs "$P_EV_S" "not only the winning one")" ]'

echo ""
echo "3. IT NAMES THE SHAPE AND NEVER A FAULT"
# A clause that names a planted fault proves nothing about reach. So the clause
# ITSELF — the paragraph, cut out of the assembled prompt — is read back and
# checked for the words that would give one away. The whole prompt cannot be
# checked this way (it talks about scores and round limits everywhere, properly),
# which is exactly why the unit of the check is the paragraph.
CLAUSE_PY="$TMPROOT/clause.py"
cat >"$CLAUSE_PY" <<'PYC'
import sys
BANNED = ("repeat", "permutation", "score", "reset", "limit")
text = open(sys.argv[1], encoding="utf-8").read()
anchor = sys.argv[2].lower()
paras = text.split("\n\n")
hit = [p for p in paras if anchor in p.lower()]
if not hit:
    print("NO-CLAUSE")
    sys.exit(0)
clause = "\n\n".join(hit)
if len(sys.argv) > 3 and sys.argv[3] == "--show":
    print(clause)
    sys.exit(0)
named = sorted({w for w in BANNED if w in clause.lower()})
print("NAMES:" + ",".join(named) if named else "clean")
PYC
check "3a. the clause is FOUND in the assembled prompt as its own paragraph" \
  '[ "$("$PY" "$CLAUSE_PY" "$P_EV" "a rule you only ever")" != NO-CLAUSE ]'
check "3b. THE FENCE — the clause names none of repeat/permutation/score/reset/limit" \
  '[ "$("$PY" "$CLAUSE_PY" "$P_EV" "a rule you only ever")" = clean ]'
check "3c. MUTATION — the fence FIRES when a fault word is injected into the clause" \
  '[ "$("$PY" "$CLAUSE_PY" "$P_EV_I" "a rule you only ever")" = "NAMES:reset,score" ]'
check "3d. …and the recheck mirror names none of them either" \
  '[ "$("$PY" "$CLAUSE_PY" "$P_RE" "fix is held only when the rule now")" = clean ]'
check "3e. and no prompt file has learned the word near-miss by naming a plant" \
  '! grep -qiE "repeated digit|permutation|does not reset|score reset" "$PROMPTS"/*.md'

echo ""
echo "4. THE MIRROR — the re-check reads a rule's fix the same way"
check "4a. a rule's fix is held only when the rule now REFUSES" \
  'says "$P_RE" "held only when the rule now refuses"'
check "4b. …a picture of the right input working is not the fix holding" \
  'says "$P_RE" "is not the fix holding"'
check "4c. …nothing settles it but the almost-right input being refused" \
  'says "$P_RE" "almost right input being refused"'
check "4d. MUTATION — all three fail with the mirror stripped" \
  '! says "$P_RE_S" "held only when the rule now refuses" &&
   ! says "$P_RE_S" "is not the fix holding" &&
   ! says "$P_RE_S" "almost right input being refused"'
check "4e. CONTROL — the recheck round still has its own job, unchanged" \
  'says "$P_RE" "say whether its fix HOLDS" && says "$P_RE" "Do not open new findings"'

echo ""
echo "5. THE VOLUNTEERED LANE IS OFFERED — and still cannot move the grade"
check "5a. the worker is told the lane is EXPECTED OUTPUT, in the breath that tells it to break a rule" \
  'says "$P_EV" "where that one is EXPECTED output"'
check "5b. MUTATION — that fails with the clause stripped, so it is not S251's block answering for it" \
  '! says "$P_EV_S" "where that one is EXPECTED output"'
check "5c. …said as a fault nobody wrote a criterion for" \
  'says "$P_EV" "a fault nobody wrote a criterion for"'
check "5d. MUTATION — that fails with the clause stripped too" \
  '! says "$P_EV_S" "a fault nobody wrote a criterion for"'
check "5e. …and in the same breath, that it is still fenced out of the grade" \
  'says "$P_EV" "fenced out of your grade"'
check "5f. MUTATION — that fails with the clause stripped" \
  '! says "$P_EV_S" "fenced out of your grade"'
check "5g. CONTROL — S251's own lane block is still there and still says what it said" \
  'says "$P_EV_S" "volunteered" && says "$P_EV_S" "never a send-back"'
# S263 — SAME CURE, SAME REASON as lcars-xo-uncontracted 2a. The scorer now
# CARRIES the key to the filer (it is handed the SCORED file, and the raw verdict
# is deleted), so "never heard the word" is no longer the fence. The fence is
# that nothing which DECIDES anything reads it: one executable line, and it is
# the pass-through.
check "5h. THE FENCE HOLDS — the scorer CARRIES the lane and still never READS it" \
  'ex="$(grep -n "volunteered" "$SCORE_PY" | grep -v ":[[:space:]]*#")";
   [ "$(printf "%s\n" "$ex" | grep -c .)" = "1" ] &&
   printf "%s" "$ex" | grep -q "S263 PASS-THROUGH"'
check "5i. …and neither has the shell that drives the look" \
  '! grep -q "volunteered" "$REPO_ROOT/skills/lcars-xo/xo.sh"'

echo ""
echo "6. THE TRADE THAT PAID FOR IT"
# evaluate.md is held under 689 lines by three other suites, on purpose: a fact
# about one round's inputs belongs in run.sh, not in the template. The clause was
# paid for out of the file, not added on top of it.
check "6a. evaluate.md is still under its 689-line ceiling" \
  '[ "$(grep -c "" "$PROMPTS/evaluate.md")" -lt 689 ]'
check "6b. the per-round pre-launch fact is said by the ROUND, not by the template" \
  '! grep -qi "round before anything is served" "$PROMPTS/evaluate.md" &&
   says "$P_EV" "live-check/cli.md"'
check "6c. …and the round that IS before the launch still says it, whole" \
  '( cd "$repo" && XO_PROMPT_DUMP="$TMPROOT/prompt-pre.txt" LCARS_WORKER_ADAPTER="$DUMP" \
      LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
      LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true LCARS_XO_PRELAUNCH=1 \
      bash "$RUNSH" spawn-number-one --mission lcars-1 --mode evaluate \
        --outdir "$TMPROOT/out-pre" ) >/dev/null 2>&1;
   says "$TMPROOT/prompt-pre.txt" "THIS ROUND IS BEFORE THE LAUNCH" &&
   says "$TMPROOT/prompt-pre.txt" "asked ONCE for a different"'

echo ""
echo "7. ALL THREE LIVE-CHECK NEAR-MISS ITEMS REACH THE ASSEMBLED PROMPT"
LIVE_CHECK_PY="$TMPROOT/live-check-items.py"
cat >"$LIVE_CHECK_PY" <<'PYC'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
headings = (
    "Break a CLI rule with the near miss",
    "Break a page rule with the near miss",
    "Break a workflow rule with the near miss",
)
items = []
for heading in headings:
    match = re.search(
        rf"^### \d+\. {re.escape(heading)}\n.*?(?=^---$|^### \d+\. |\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if match:
        items.append(match.group(0))

mode = sys.argv[2]
if mode == "count":
    print(len(items))
elif mode == "near-miss":
    print("yes" if any(re.search(r"near miss", item, re.I) for item in items) else "no")
elif mode == "forbidden":
    forbidden = ("repeat", "permutation", "score", "reset", "limit", "duplicate", "collision")
    found = sorted({word for item in items for word in forbidden if re.search(rf"\b{word}\b", item, re.I)})
    print(",".join(found) if found else "clean")
PYC
check "7a. near miss appears inside an assembled live-check checklist item" \
  '[ "$("$PY" "$LIVE_CHECK_PY" "$P_EV" near-miss)" = yes ]'
check "7b. all three new checklist items are in their assembled prompts" \
  '[ "$("$PY" "$LIVE_CHECK_PY" "$P_EV" count)" -eq 1 ] &&
   [ "$("$PY" "$LIVE_CHECK_PY" "$P_WEB" count)" -eq 1 ] &&
   [ "$("$PY" "$LIVE_CHECK_PY" "$P_WORK" count)" -eq 1 ]'
check "7c. the assembled CLI near-miss item is present" \
  'says "$P_EV" "Break a CLI rule with the near miss"'
check "7d. the assembled web near-miss item is present" \
  'says "$P_WEB" "Break a page rule with the near miss"'
check "7e. the assembled workflow near-miss item is present" \
  'says "$P_WORK" "Break a workflow rule with the near miss"'
check "7f. none of the forbidden words appears in the three added items" \
  '[ "$("$PY" "$LIVE_CHECK_PY" "$P_EV" forbidden)" = clean ] &&
   [ "$("$PY" "$LIVE_CHECK_PY" "$P_WEB" forbidden)" = clean ] &&
   [ "$("$PY" "$LIVE_CHECK_PY" "$P_WORK" forbidden)" = clean ]'

echo ""
echo "8. S265 — THE NEAR MISS IS A CONCRETE TABLE, NOT AN ABSTRACTION"
# WHY. S262's reviewer DID item 9. It gave a duplicate, an empty name, a
# whitespace name and an invalid subcommand within minutes of having a shell —
# so the prose route works. It then rated `t-001-ac4` ("with a name already
# registered") MET, its own note saying it "broke the rule both ways", having
# only ever offered the SAME string twice. `habit add "Exercise"` then
# `habit add "exercise"` registers two habits, and the buddy filed it as #151.
# Nothing in the machinery blocked that row: filing was open, the criterion
# existed, the row was reachable. It simply did not think of the case variant.
# So the cure is not a gate (that was the cut S259, measured at 0 declarations
# out of 95) — it is to stop asking for "an input that is almost valid" and
# hand over the list of near misses that actually catch bugs, each row saying
# what it is FOR so the reviewer picks instead of running all six blindly.
#
# IT LIVES IN THE LIVE-CHECK FILES, which run.sh cats WHOLE into the prompt
# (`number_one_checklists`), so `evaluate.md`'s 689-line ceiling — pinned by 6a
# here, by lcars-xo-uncontracted and by lcars-xo-live-consent — is not touched
# at all. 8i is the mutation: the same assertions against a checklist dir with
# the table cut out, where they must go red.

# A live-check dir with the concrete table STRIPPED, in all three mediums.
LC_STRIPPED="$TMPROOT/live-check-stripped"
mkdir -p "$LC_STRIPPED"
cp "$REPO_ROOT/skills/lcars-run/live-check"/*.md "$LC_STRIPPED"/
for f in cli web workflow; do
  "$PY" - "$LC_STRIPPED/$f.md" <<'PYLC'
import sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
MARKS = ("NEAR MISSES THAT CATCH BUGS", "| the near miss ", "| what it is FOR ")
keep = [para for para in text.split("\n\n")
        if not any(m in para for m in MARKS)]
open(p, "w", encoding="utf-8").write("\n\n".join(keep))
PYLC
done

prompt_lc() { # <out-prompt> <mode> <live-check-dir>
  ( cd "$repo" && XO_PROMPT_DUMP="$1" LCARS_WORKER_ADAPTER="$DUMP" \
      LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
      LCARS_LIVE_CHECK_DIR="$3" \
      bash "$RUNSH" spawn-number-one --mission lcars-1 \
        --mode "$2" --outdir "$TMPROOT/out-$$-$RANDOM" ) >/dev/null 2>&1
}

P_EV_LCS="$TMPROOT/prompt-evaluate-lcstripped.txt"
prompt_lc "$P_EV_LCS" evaluate "$LC_STRIPPED"
criteria_for web
P_WEB_LCS="$TMPROOT/prompt-web-lcstripped.txt"
prompt_lc "$P_WEB_LCS" evaluate "$LC_STRIPPED"
criteria_for workflow
P_WORK_LCS="$TMPROOT/prompt-workflow-lcstripped.txt"
prompt_lc "$P_WORK_LCS" evaluate "$LC_STRIPPED"
criteria_for cli

check "8a. the assembled CLI prompt carries the concrete enumeration, named as a list of near misses that CATCH BUGS" \
  'says "$P_EV" "near misses that catch bugs"'
check "8b. THE HEADLINE ROW — a known-correct value, REARRANGED (the row that would have caught #151)" \
  'says "$P_EV" "a known-correct value, REARRANGED" &&
   says "$P_EV" "case flipped" && says "$P_EV" "two letters swapped"'
check "8c. …and the word the captain asked for is the one used: a REARRANGEMENT of a value already accepted" \
  'says "$P_EV" "rearrangement"'
check "8d. all six rows are in the CLI prompt" \
  'says "$P_EV" "a known-correct value, REARRANGED" &&
   says "$P_EV" "whitespace-only" &&
   says "$P_EV" "unicode look-alikes" &&
   says "$P_EV" "the numeric edges" &&
   says "$P_EV" "normalises onto one already accepted" &&
   says "$P_EV" "the almost-right identifier"'
check "8e. every row says what it is FOR — six rule shapes, one per row" \
  '[ "$(occurs "$P_EV" "\| a rule that")" -ge 6 ]'
check "8f. the reviewer is told to PICK the rows that fit the rule in front of it, not run all six" \
  'says "$P_EV" "pick the rows that fit the rule in front of you" &&
   says "$P_EV" "running all seven blindly is not the ask"'
check "8g. …and to say which rows it tried, with the exact input, and which made no sense" \
  'says "$P_EV" "say which rows you tried"'
check "8h. THE REARRANGEMENT ROW IS NAMED IN ALL THREE MEDIUMS, adapted not pasted" \
  'says "$P_WEB" "REARRANGED" && says "$P_WORK" "REARRANGED" &&
   says "$P_WEB" "near misses that catch bugs" &&
   says "$P_WORK" "near misses that catch bugs" &&
   says "$P_WEB" "already saved" && says "$P_WORK" "already recorded"'
check "8i. CONTROL — the abstract-only ask is GONE from all three (no bare \"almost valid but must be turned away\")" \
  '! says "$P_EV" "almost valid but must be turned away" &&
   ! says "$P_WEB" "almost valid but must be turned away" &&
   ! says "$P_WORK" "almost matches but must not fire"'
check "8j. CONTROL — the mutation harness reached the same seam (all three prompts assembled)" \
  '[ -s "$P_EV_LCS" ] && [ -s "$P_WEB_LCS" ] && [ -s "$P_WORK_LCS" ]'
check "8k. MUTATION — cut the table out of the checklists and 8a/8b/8d/8e go red" \
  '! says "$P_EV_LCS" "near misses that catch bugs" &&
   ! says "$P_EV_LCS" "a known-correct value, REARRANGED" &&
   ! says "$P_EV_LCS" "the almost-right identifier" &&
   [ "$(occurs "$P_EV_LCS" "\| a rule that")" -eq 0 ] &&
   ! says "$P_WEB_LCS" "REARRANGED" && ! says "$P_WORK_LCS" "REARRANGED"'
check "8l. …and the mutation removed ONLY the table — item 9 itself still stands" \
  'says "$P_EV_LCS" "Break a CLI rule with the near miss" &&
   says "$P_EV_LCS" "a refusal that never came is a fault"'
check "8m. THE CEILING IS UNTOUCHED — evaluate.md is still exactly 688 lines" \
  '[ "$(grep -c "" "$PROMPTS/evaluate.md")" -eq 688 ]'
check "8n. …and the table is NOT in evaluate.md or recheck.md at all" \
  '! grep -qi "near misses that catch bugs" "$PROMPTS"/*.md'

echo ""
echo "10. S268 — TWO WRITERS AT ONCE"
# WHY. Tonight's full re-measurement ran the look on BOTH engines against a real
# build, and both independently missed the same real defect: eight `add` calls
# fired together left ONE record, seven writes lost, every call exiting 0 in
# silence. The human stand-in found it. Neither engine did.
#
# The gap is in what the reviewer is TOLD, not in the engine. Every one of the
# six near-miss rows is a SINGLE-VALUE shape — a value rearranged, whitespace, a
# look-alike, a numeric edge, a normalising second value, an almost-right
# identifier. Not one of them involves two things happening at the same instant.
# cli.md item 4 ("Two actors — two HOMEs, two laptops") is the item that SOUNDS
# like it covers this, and it is two actors IN SEQUENCE — which is exactly what
# both engines did: two homes, one after the other, never two writers at once.
#
# So the shape goes where the table lives, because the table is the mechanism
# that is PROVEN to be used (on this run the reviewer's own evidence file was
# headed "ROW 1 — a known-correct value, REARRANGED", on both engines), adapted
# per medium — two processes, two requests, two runs — and item 4 is made to
# admit out loud that in sequence is not the same check as at the same instant.
#
# EVERY CHECK HERE IS ON THE ASSEMBLED PROMPT, and 10m-10p are the mutation: a
# live-check dir with ONLY the new shape cut out, through the same real seam,
# where 10a-10l must go red. Not a source grep — a behaviour on a real prompt.

# A live-check dir with ONLY the new shape removed: the table row in all three
# mediums, and cli item 4's at-the-same-instant paragraph. Everything else —
# the six rows, the table head, item 4's own body — stays.
LC_NOCONC="$TMPROOT/live-check-noconc"
mkdir -p "$LC_NOCONC"
cp "$REPO_ROOT/skills/lcars-run/live-check"/*.md "$LC_NOCONC"/
for f in cli web workflow; do
  "$PY" - "$LC_NOCONC/$f.md" <<'PYNC'
import sys

# A REVERT, not an approximation: every string S268 added to the checklists is
# named here and taken back out, so 10a-10m are measured against the file as it
# stood when BOTH engines missed the overlapping write. Table rows and the
# fenced expect key go line by line; the rest are exact spans.
ROWS = ("two writers at once", "two requests in flight at once",
        "two runs overlapping")
LINES = ("inSequenceIsNotAtTheSameInstant",)
PARA = "IN SEQUENCE is a different check"
SPANS = (
    ("\nSeparately, for the writes launched together: fewer records stored than calls\nthat reported success — a write lost with nobody told.", ""),
    (", the interaction at the end, and the\nwrites you launched together with what was stored afterwards.", ", and the interaction at the end."),
)

p = sys.argv[1]
text = open(p, encoding="utf-8").read()

kept = []
for para in text.split("\n\n"):
    if PARA in para:
        continue
    lines = []
    for line in para.split("\n"):
        low = line.lower()
        if line.lstrip().startswith("|") and any(r in low for r in ROWS):
            continue
        if any(m in line for m in LINES):
            if lines and lines[-1].rstrip().endswith(","):
                lines[-1] = lines[-1].rstrip()[:-1]
            continue
        lines.append(line)
    kept.append("\n".join(lines))
text = "\n\n".join(kept)

for span, back in SPANS:
    text = text.replace(span, back)
# the head sentence, back to six
HEAD_NEW = ("SEVEN NEAR MISSES THAT CATCH BUGS, and what each one is FOR.** Six rearrange\n"
            "a value; the last rearranges the timing. Pick the rows that fit the rule in\n"
            "front of you — running all seven blindly is not the ask.")
HEAD_OLD = ("SIX NEAR MISSES THAT CATCH BUGS, and what each one is FOR.** Pick the rows\n"
            "that fit the rule in front of you — running all six blindly is not the ask.")
assert HEAD_NEW in text, p
text = text.replace(HEAD_NEW, HEAD_OLD)
open(p, "w", encoding="utf-8").write(text)
PYNC
done

P_EV_NC="$TMPROOT/prompt-evaluate-noconc.txt"
prompt_lc "$P_EV_NC" evaluate "$LC_NOCONC"
criteria_for web
P_WEB_NC="$TMPROOT/prompt-web-noconc.txt"
prompt_lc "$P_WEB_NC" evaluate "$LC_NOCONC"
criteria_for workflow
P_WORK_NC="$TMPROOT/prompt-workflow-noconc.txt"
prompt_lc "$P_WORK_NC" evaluate "$LC_NOCONC"
criteria_for cli

# -- 1. the shape is NAMED in the assembled prompt, with what it is FOR -------
check "10a. the CLI prompt names the shape: two writers at once" \
  'says "$P_EV" "two writers at once"'
check "10b. …and says it is AT ONCE, not one after the other" \
  'says "$P_EV" "start the second before the first has finished" &&
   says "$P_EV" "one after the other"'
check "10c. …and says what it is FOR, in the table.s own voice" \
  'says "$P_EV" "any rule about something being stored, counted, kept unique, or shared"'
check "10c2. …and the table head accounts for the seventh row, saying what makes it different" \
  'says "$P_EV" "six rearrange a value" && says "$P_EV" "the last rearranges the timing" &&
   says "$P_WEB" "the last rearranges the timing" &&
   says "$P_WORK" "the last rearranges the timing"'
check "10d. …and names the mechanism: read, change, write back, last writer wins" \
  'says "$P_EV" "reads a whole file, changes it and writes it back" &&
   says "$P_EV" "only the last writer.s work"'
check "10e. …and THE GIVEAWAY: nothing fails, every caller is told it succeeded" \
  'says "$P_EV" "the giveaway is that nothing fails" &&
   says "$P_EV" "every caller is told it succeeded"'

# -- 2. what to inspect afterwards: the store, NOT the exit codes -------------
check "10f. the prompt says to IGNORE the exit codes, naming that they will all be zero" \
  'says "$P_EV" "ignore the exit codes" && says "$P_EV" "all be zero"'
check "10g. …and to compare the STORED RESULT against the calls that claimed success" \
  'says "$P_EV" "compare the stored result against the number of calls that claimed success"'

# -- 3. item 4 no longer reads as if it covered this -------------------------
check "10h. item 4 says IN SEQUENCE is a different check from AT THE SAME INSTANT" \
  'says "$P_EV" "two actors in sequence is a different check from two actors at the same instant"'
check "10i. …and admits that item 4 as written is only the first of the two" \
  'says "$P_EV" "as written, is only the first one"'
check "10j. …and names the overlapping write as its own check, with what to read" \
  'says "$P_EV" "treat the overlapping write as its own check" &&
   says "$P_EV" "without waiting for the first to return" &&
   says "$P_EV" "read what was stored instead of the exit codes"'
check "10k. …and the FENCED reader is told the same thing, in lockstep" \
  'says "$P_EV" "inSequenceIsNotAtTheSameInstant"'

# -- 4. adapted per medium, not pasted three times ---------------------------
check "10l. WEB — two requests in flight, judged on what is saved vs what was accepted" \
  'says "$P_WEB" "two requests in flight at once" &&
   says "$P_WEB" "fire the second before the first has come back" &&
   says "$P_WEB" "the giveaway is that nothing fails" &&
   says "$P_WEB" "compare what is saved against the number of submissions that reported success" &&
   ! says "$P_WEB" "two writers at once"'
check "10m. WORKFLOW — two runs overlapping, judged on what was recorded vs runs that went green" \
  'says "$P_WORK" "two runs overlapping" &&
   says "$P_WORK" "start the second while the first is still going" &&
   says "$P_WORK" "the giveaway is that nothing fails" &&
   says "$P_WORK" "compare what was recorded against the number of runs that finished green" &&
   ! says "$P_WORK" "two writers at once"'

# -- 5. CONTROL — nothing else moved ----------------------------------------
check "10n. CONTROL — all six original rows are still there, unchanged, in the CLI prompt" \
  'says "$P_EV" "a known-correct value, REARRANGED" &&
   says "$P_EV" "whitespace-only" &&
   says "$P_EV" "unicode look-alikes" &&
   says "$P_EV" "the numeric edges" &&
   says "$P_EV" "normalises onto one already accepted" &&
   says "$P_EV" "the almost-right identifier" &&
   [ "$(occurs "$P_EV" "\| a rule that")" -ge 6 ]'
check "10o. CONTROL — item 4 still is what it was: its heading and its own DEFECTs" \
  'says "$P_EV" "Two actors — two HOMEs, two laptops" &&
   says "$P_EV" "actor B sees none of actor A.s state"'
check "10p. CONTROL — evaluate.md paid for none of this: still exactly 688 lines" \
  '[ "$(grep -c "" "$PROMPTS/evaluate.md")" -eq 688 ] &&
   ! grep -qi "two writers at once" "$PROMPTS"/*.md'
check "10q. CONTROL — the surgical mutation reached the same seam (all three assembled)" \
  '[ -s "$P_EV_NC" ] && [ -s "$P_WEB_NC" ] && [ -s "$P_WORK_NC" ]'

# -- 6. MUTATION — cut ONLY the new shape and every check above goes red -----
check "10r. MUTATION — 10a-10e go red: the shape is gone from the CLI prompt" \
  '! says "$P_EV_NC" "two writers at once" &&
   ! says "$P_EV_NC" "start the second before the first has finished" &&
   ! says "$P_EV_NC" "any rule about something being stored, counted, kept unique, or shared" &&
   ! says "$P_EV_NC" "the giveaway is that nothing fails"'
check "10s. MUTATION — 10f/10g go red: nothing left says what to inspect afterwards" \
  '! says "$P_EV_NC" "ignore the exit codes" &&
   ! says "$P_EV_NC" "compare the stored result against the number of calls that claimed success"'
check "10t. MUTATION — 10h-10k go red: item 4 is back to sounding like it covers it" \
  '! says "$P_EV_NC" "two actors in sequence is a different check from two actors at the same instant" &&
   ! says "$P_EV_NC" "treat the overlapping write as its own check" &&
   ! says "$P_EV_NC" "inSequenceIsNotAtTheSameInstant"'
check "10u. MUTATION — 10l/10m go red in the other two mediums too" \
  '! says "$P_WEB_NC" "two requests in flight at once" &&
   ! says "$P_WORK_NC" "two runs overlapping"'
check "10v. …and the mutation removed ONLY the new shape — the six rows and item 4 still stand" \
  'says "$P_EV_NC" "a known-correct value, REARRANGED" &&
   says "$P_EV_NC" "the almost-right identifier" &&
   says "$P_EV_NC" "Two actors — two HOMEs, two laptops" &&
   says "$P_WEB_NC" "near misses that catch bugs" &&
   says "$P_WORK_NC" "near misses that catch bugs"'

echo ""
echo "11. S270 — A RISK OPINION IS NOT A REASON TO SKIP"
# WHY, measured. S268 put the seventh row — "two writers at once" — into the
# prompt, and the very next run of the look READ IT, NAMED IT, AND DECLINED IT:
# "two writers at the SAME INSTANT (live-check item 4 second half / item 9 last
# row) — I verified two actors in sequence on separate HOMEs but did not fire
# concurrent simultaneous writes; for a single-user local CLI that reads-
# modifies-writes one file the risk is low, but I did not exercise the overlap,
# so I am recording it as not done." Its transcript agrees: 17 bash calls, not
# one `&`, `wait`, loop or `xargs -P`. Strictly sequential.
#
# So the row bought DISCLOSURE, not detection — and the ground it gave was a
# RISK JUDGEMENT, not an inability. That is the one variable this session
# changes. Note the irony it walked into: "a single-user CLI that reads-
# modifies-writes one file" is not a reason the overlap is safe, it is the
# exact description of the thing that loses writes. It recited the fault's own
# preconditions as grounds for skipping the check for it.
#
# THE CHANGE IS PROSE, NOT A GATE. A gate keyed on a voluntary declaration was
# already measured dead (0 declarations in 95) and is out of scope. The row now
# says that skipping it needs a FACT about the product — "nothing here writes
# to shared storage at all", checkably true or false — names the low-risk /
# single-user / local-CLI reasoning as NOT a reason, and says the check is
# cheap. Adapted per medium.
#
# 11k is the standard S268 set: the revert is proved BYTE-IDENTICAL to
# `git show HEAD:` before anything is measured against it, so the mutation is a
# true revert and not an approximation.

# A live-check dir with ONLY this session's text taken back out. The spans are
# exact and contiguous, so removing them must reproduce HEAD byte for byte.
LC_NORISK="$TMPROOT/live-check-norisk"
mkdir -p "$LC_NORISK"
cp "$REPO_ROOT/skills/lcars-run/live-check"/*.md "$LC_NORISK"/
"$PY" - "$LC_NORISK" <<'PYRK'
import os, sys

d = sys.argv[1]

ADD_CLI = ' **Skipping this row needs a FACT about the product, not an estimate of how likely it is.** The one honest ground for passing it over is that nothing here writes to shared storage at all — a thing that is checkably true or false. "The risk is low", "it is single-user", "it is only a local CLI" are NOT grounds: a single-user tool that reads one file, changes it and writes it back is the exact description of the thing that loses writes, so that reasoning recites the fault\'s own preconditions as the reason not to look for it. And the check is cheap — a handful of calls launched in the background and a count, not an investigation.'

ADD_WEB = ' **Skipping this row needs a FACT about the product, not an estimate of how likely it is.** The one honest ground for passing it over is that nothing behind this page writes to shared storage at all — a thing that is checkably true or false. "The risk is low", "only one person uses it", "it is just a form" are NOT grounds: a server that reads one record, changes it and writes it back for one person at a time is the exact description of the thing that loses writes, so that reasoning recites the fault\'s own preconditions as the reason not to look for it. And the check is cheap — two submissions fired without waiting, then a count, not an investigation.'

ADD_WORK = ' **Skipping this row needs a FACT about the product, not an estimate of how likely it is.** The one honest ground for passing it over is that nothing in this workflow writes to shared storage at all — no cache, no artifact name, no state file, no branch — a thing that is checkably true or false. "The risk is low", "it only ever runs on its own", "it is just a nightly job" are NOT grounds: a step that reads one file, changes it and writes it back is the exact description of the thing that loses writes, so that reasoning recites the fault\'s own preconditions as the reason not to look for it. And the check is cheap — two runs started without waiting, then a count, not an investigation.'

ADD_ITEM4 = ('\n**And skipping that second check needs a FACT, not a judgement about how\n'
             'likely it is**: the one honest ground is that nothing here writes to shared\n'
             'storage at all. "The risk is low", "it is single-user", "it is only a local\n'
             'CLI" are the conditions under which writes are lost, not conditions under\n'
             'which they are safe. It costs a handful of calls launched in the background\n'
             'and a count.')

ADD_KEY = "; skipping it needs the FACT that nothing here writes to shared storage, never a judgement that the risk is low"

PLAN = {"cli.md": (ADD_CLI, ADD_ITEM4, ADD_KEY),
        "web.md": (ADD_WEB,),
        "workflow.md": (ADD_WORK,)}

for fname, spans in PLAN.items():
    p = os.path.join(d, fname)
    text = open(p, encoding="utf-8").read()
    for span in spans:
        assert text.count(span) == 1, (fname, text.count(span))
        text = text.replace(span, "")
    open(p, "w", encoding="utf-8").write(text)
PYRK

# THE REVERT IS PROVED BEFORE IT IS USED: byte for byte against HEAD.
revert_is_head() {
  local f
  for f in cli web workflow; do
    git -C "$REPO_ROOT" show "HEAD:skills/lcars-run/live-check/$f.md" \
      >"$TMPROOT/head-$f.md" 2>/dev/null || return 1
    cmp -s "$TMPROOT/head-$f.md" "$LC_NORISK/$f.md" || return 1
  done
  return 0
}

P_EV_RK="$TMPROOT/prompt-evaluate-norisk.txt"
prompt_lc "$P_EV_RK" evaluate "$LC_NORISK"
criteria_for web
P_WEB_RK="$TMPROOT/prompt-web-norisk.txt"
prompt_lc "$P_WEB_RK" evaluate "$LC_NORISK"
criteria_for workflow
P_WORK_RK="$TMPROOT/prompt-workflow-norisk.txt"
prompt_lc "$P_WORK_RK" evaluate "$LC_NORISK"
criteria_for cli

# -- 1. a risk estimate is not a reason to skip ------------------------------
check "11a. the CLI prompt says skipping the row needs a FACT about the product, not an estimate" \
  'says "$P_EV" "skipping this row needs a FACT about the product, not an estimate of how likely it is"'
check "11b. …and names the low-risk / single-user / local-CLI reasoning as NOT grounds" \
  'says "$P_EV" "\"the risk is low\", \"it is single-user\", \"it is only a local CLI\" are NOT grounds"'
check "11c. …and states the irony: that reasoning recites the fault.s own preconditions" \
  'says "$P_EV" "is the exact description of the thing that loses writes" &&
   says "$P_EV" "recites the fault.s own preconditions as the reason not to look for it"'

# -- 2. the factual ground that WOULD justify skipping -----------------------
check "11d. the prompt states the one honest ground, and that it is checkable" \
  'says "$P_EV" "the one honest ground for passing it over is that nothing here writes to shared storage at all" &&
   says "$P_EV" "a thing that is checkably true or false"'

# -- 3. and that the check is cheap ------------------------------------------
check "11e. the prompt says the check is cheap — calls and a count, not an investigation" \
  'says "$P_EV" "the check is cheap" &&
   says "$P_EV" "a handful of calls launched in the background and a count, not an investigation"'

# -- 4. item 4's matching half carries the same correction -------------------
check "11f. item 4.s second half needs a FACT too, and says those are the losing conditions" \
  'says "$P_EV" "skipping that second check needs a FACT, not a judgement about how likely it is" &&
   says "$P_EV" "are the conditions under which writes are lost, not conditions under which they are safe"'
check "11g. …and the FENCED reader is told the same, in lockstep" \
  'says "$P_EV" "skipping it needs the FACT that nothing here writes to shared storage, never a judgement that the risk is low"'

# -- 5. adapted per medium, not pasted ---------------------------------------
check "11h. WEB — the same correction in the page.s own terms, reaching its assembled prompt" \
  'says "$P_WEB" "nothing behind this page writes to shared storage at all" &&
   says "$P_WEB" "\"only one person uses it\", \"it is just a form\" are NOT grounds" &&
   says "$P_WEB" "two submissions fired without waiting, then a count, not an investigation" &&
   ! says "$P_WEB" "it is only a local CLI"'
check "11i. WORKFLOW — the same correction in the run.s own terms, reaching its assembled prompt" \
  'says "$P_WORK" "nothing in this workflow writes to shared storage at all" &&
   says "$P_WORK" "no cache, no artifact name, no state file, no branch" &&
   says "$P_WORK" "two runs started without waiting, then a count, not an investigation" &&
   ! says "$P_WORK" "it is only a local CLI"'

# -- 6. CONTROL — the row kept everything it already said --------------------
check "11j. CONTROL — the seventh row still says what it is FOR, the giveaway, and what to compare" \
  'says "$P_EV" "two writers at once" &&
   says "$P_EV" "any rule about something being stored, counted, kept unique, or shared" &&
   says "$P_EV" "the giveaway is that nothing fails" &&
   says "$P_EV" "every caller is told it succeeded" &&
   says "$P_EV" "compare the stored result against the number of calls that claimed success"'
check "11k. CONTROL — the other six rows and the table head are untouched" \
  'says "$P_EV" "a known-correct value, REARRANGED" &&
   says "$P_EV" "whitespace-only" && says "$P_EV" "unicode look-alikes" &&
   says "$P_EV" "the numeric edges" &&
   says "$P_EV" "normalises onto one already accepted" &&
   says "$P_EV" "the almost-right identifier" &&
   says "$P_EV" "six rearrange a value" &&
   says "$P_EV" "the last rearranges the timing" &&
   [ "$(occurs "$P_EV" "\| a rule that")" -ge 6 ]'
check "11l. CONTROL — evaluate.md paid for none of this: still exactly 688 lines and clean of it" \
  '[ "$(grep -c "" "$PROMPTS/evaluate.md")" -eq 688 ] &&
   ! grep -qi "needs a FACT about the product" "$PROMPTS"/*.md'
check "11m. CONTROL — the revert is BYTE-IDENTICAL to git show HEAD: in all three mediums" \
  'revert_is_head'
check "11n. CONTROL — the reverted dir reached the same seam (all three assembled)" \
  '[ -s "$P_EV_RK" ] && [ -s "$P_WEB_RK" ] && [ -s "$P_WORK_RK" ]'

# -- 7. MUTATION — revert this session only, and 11a-11i go red --------------
check "11o. MUTATION — 11a-11e go red: the CLI row is back to allowing a risk opinion" \
  '! says "$P_EV_RK" "needs a FACT about the product" &&
   ! says "$P_EV_RK" "are NOT grounds" &&
   ! says "$P_EV_RK" "nothing here writes to shared storage at all" &&
   ! says "$P_EV_RK" "the check is cheap"'
check "11p. MUTATION — 11f/11g go red: item 4 and its fenced key lose the correction too" \
  '! says "$P_EV_RK" "skipping that second check needs a FACT" &&
   ! says "$P_EV_RK" "never a judgement that the risk is low"'
check "11q. MUTATION — 11h/11i go red in the other two mediums" \
  '! says "$P_WEB_RK" "nothing behind this page writes to shared storage" &&
   ! says "$P_WORK_RK" "nothing in this workflow writes to shared storage"'
check "11r. …and the revert removed ONLY this session.s text — the seventh row still stands whole" \
  'says "$P_EV_RK" "two writers at once" &&
   says "$P_EV_RK" "the giveaway is that nothing fails" &&
   says "$P_EV_RK" "compare the stored result against the number of calls that claimed success" &&
   says "$P_EV_RK" "two actors in sequence is a different check from two actors at the same instant" &&
   says "$P_WEB_RK" "two requests in flight at once" &&
   says "$P_WORK_RK" "two runs overlapping"'

echo ""
echo "9. ZERO SPEND"
check "9a. no faked engine CLI was ever invoked" '[ ! -s "$SPEND_LOG" ]'

echo ""
printf 'lcars-xo-near-miss: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
