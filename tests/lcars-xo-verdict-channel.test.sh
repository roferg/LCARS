#!/usr/bin/env bash
#
# THE VERDICT CHANNEL — Number One hands its file over by SPEAKING it.
#
# WHY THIS FILE EXISTS. `evaluate.md` tells the worker "you look, you judge
# against the record, and you write one file". That one file — `xo-verdict.json`
# — was the ONLY reason the role needed any write capability at all, so the
# cheapest way to stop depending on one is to stop needing one.
#
# NOT A BUG FIX, AND THERE WAS NO OUTAGE (fix round 1 corrected the record here).
# On copilot a write tool is MODEL-DEPENDENT: the same `--available-tools` list
# has `create` with `--model claude-opus-4.8` and no file-writing tool at all
# without one — measured live on 2026-10-05 against copilot 1.0.92, and written
# up with the numbers in `adapter_tools` (worker-adapter.sh). S194's write-tool
# floor in run.sh supplies that model and it holds; `create` works; the other
# read roles keep it. What this channel buys is INDEPENDENCE — a reviewer that
# needs no write capability cannot be broken by anything that happens to one.
#
# So the write tool is not replaced — it is RETIRED, for this one role. The
# worker says its file on stdout, between two delimiters it is asked for by name,
# and the HARNESS writes the file. Nothing about the look changes; the pen moves
# to our side of the door.
#
# A RECORD, NOT AN INFERENCE. `ORCHESTRATION.md` names this failure class (S147,
# S156, S188) and this very round has lost sessions to it. Scraping the first `{`
# out of a model's reply is an inference: it guesses which brace-run is the
# answer, and on `evaluate` — which may write EITHER a verdict OR a request to
# look further — it cannot even tell WHICH file it is holding. So the prompt asks
# the worker to FRAME its answer and to NAME the file on the opening line, and
# the harness reads exactly that frame and nothing else.
#
#   ===LCARS-XO-BEGIN xo-verdict.json===
#   { … }
#   ===LCARS-XO-END===
#
# WHAT IS DRIVEN HERE
#   1  the prompt ASKS for the frame, and names both delimiters and the filename
#   2  a worker that writes NO file but frames its verdict → the harness writes it
#   3  CONTROL — a worker that DOES write the file → that file is used, byte for
#      byte, and its spoken block is never consulted
#   4  prose with no frame → an HONEST failure naming what was missing
#   5  a frame around malformed JSON → the same, naming that
#   6  the FILENAME is read off the frame — a framed `xo-actions.json` becomes
#      xo-actions.json, not a verdict
#   7  END TO END — a real `xo.sh evaluate` whose worker only ever SPEAKS still
#      reaches a scored verdict, and the look RECORDS which path it came by
#   8  the tool lists — copilot's search tool under its modern name `rg`,
#      `number-one` with no write tool and no shell, the claude column untouched,
#      and (8n-8w) the comments that record WHY, pinned against the false reason
#      a first cut wrote in as dated fact
#   9  a LIVE control (opt-in, free) — one real copilot call through the corrected
#      list, proving it can search AND frame a verdict with no write tool
#
# ZERO SPEND. No worker CLI runs. A PATH shim fakes BOTH `claude` and `copilot`
# and counts every invocation; the count is asserted at the end. Section 9 is the
# one exception and it is OFF unless $LCARS_XO_CHANNEL_LIVE=1.
#
# Usage: bash tests/lcars-xo-verdict-channel.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="${LCARS_XO_SCRIPT:-$REPO_ROOT/skills/lcars-xo/xo.sh}"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"
REPORT_PY="$REPO_ROOT/skills/lcars-xo/xo-report.py"
CRITERIA_PY="$REPO_ROOT/skills/lcars-xo/xo-criteria.py"
PY="${LCARS_PYTHON_BIN:-python3}"
CAGE="$REPO_ROOT/tests/lib/cage.py"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }

# THE REAL ENGINE, RESOLVED BEFORE THE SHIM SHADOWS IT. Section 9's live control
# needs the actual CLI, and after the next block `copilot` on PATH is the fake —
# which is exactly the zero-spend property the rest of this file relies on.
#
# AND IT MUST BE THE REAL ONE, not VS Code's re-invoking shim (S217/S231, the
# whole reason `worker-guard.sh` exists). On this machine `command -v copilot`
# resolves to that shim, which calls `copilot` BACK OFF PATH — and PATH is about
# to be our fake. Measured: the live control silently billed nothing and tested
# nothing, because the shim's re-invocation landed in the counter below. So the
# known absolute locations win, exactly as lcars_worker_bin_prefer_real prefers
# them, and the counter at the end is what proves the real one was reached.
REAL_COPILOT=""
for cand in /opt/homebrew/bin/copilot /usr/local/bin/copilot; do
  [ -x "$cand" ] && { REAL_COPILOT="$cand"; break; }
done
[ -n "$REAL_COPILOT" ] || REAL_COPILOT="$(command -v copilot 2>/dev/null || true)"

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

echo "lcars xo — THE VERDICT CHANNEL: the worker speaks its file, the harness writes it"

BEGIN_V='===LCARS-XO-BEGIN xo-verdict.json==='
BEGIN_A='===LCARS-XO-BEGIN xo-actions.json==='
END_MARK='===LCARS-XO-END==='

# ===========================================================================
# THE RIG — a real repo, a real mission, a real worker-adapter, a fake engine
# ===========================================================================
PROD="$TMPROOT/prod"; mkdir -p "$PROD"
cat >"$PROD/relay.py" <<'PYEOF'
import sys
args = sys.argv[1:]
if not args or args[0] in ("-h", "--help"):
    print("usage: relay [file|list]")
    sys.exit(0)
print("relay: %s" % " ".join(args))
PYEOF

new_repo() { # <dir-stem>
  local repo
  repo="$(mktemp -d "$TMPROOT/$1.XXXX")"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  cp "$PROD/relay.py" "$repo/relay.py"
  printf 'the page\n' >"$repo/site.txt"
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  git -C "$repo" branch -q feat/relay 2>/dev/null
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'CJ'
{
  "cloneId": "aaaaaaaa",
  "model": "claude-sonnet",
  "projectName": "relay",
  "contextFile": null,
  "stack": null,
  "testCommand": "true",
  "worktreeSetupCommand": null,
  "comprehensionBudget": 1200,
  "numberOne": {"enabled": true, "engine": "copilot"},
  "created": "2026-05-30T00:00:00Z"
}
CJ
  printf '%s' "$repo"
}

plant() { # <repo> <id>
  local repo="$1" id="$2" m="$1/.git/lcars/missions/$2"
  mkdir -p "$m/xo"
  cat >"$m/state.json" <<SJ
{
  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-10-04T10:00:00Z"},
  "id": "$id",
  "type": "feature",
  "title": "Request Relay",
  "stage": "verify",
  "branch": "feat/relay",
  "prUrl": "https://github.com/x/y/pull/7",
  "created": "2026-10-04T10:00:00Z",
  "githubIssue": 42
}
SJ
  cat >"$m/prd.md" <<'PRD'
# Request Relay

## What we are building
A relay that files a record and lists it back.

## Acceptance criteria
- prd-1: relay file stores the title it was given
PRD
  cat >"$m/plan.json" <<'PL'
{"tickets": [
  {"id": "t-1",
   "entrypoints": [{"kind": "cli", "path": "relay.py",
                    "realRunTest": "tests/test_cli.py",
                    "realRunProof": "it runs relay.py as a subprocess"}],
   "acceptanceCriteria": [
     {"text": "relay file stores the title it was given", "notVisual": true,
      "kind": "works", "serves": "prd-1", "direction": "delivers"}]}]}
PL
  printf '%s' "$m"
}

# The ledger a scorer will accept, as the worker would SAY it.
verdict_json() { # <status>
  cat <<JS
{"score": "medium", "summary": "I ran the CLI and read what it printed.",
 "criteria": [{"id": "prd-1", "text": "relay file stores a record",
   "impact": "high", "impactWhy": "it is the whole product",
   "status": "$1", "evidence": "transcript", "checkedBy": "cli",
   "shot": "03-happy-path",
   "note": "I filed nonce-7 and listed it back and the record was there",
   "action": "Ran relay.py file then relay.py list.",
   "reason": "Impact high because it is the product. I tried filing a record; I saw it listed back (evidence: 03-happy-path.txt). Outcome: it worked."}],
 "gaps": [], "escalations": [], "alsoChecked": [],
 "couldNot": []}
JS
}

# --- THE FAKE ENGINE -------------------------------------------------------
# It is a WORKER BINARY, not an adapter: the REAL worker-adapter.sh runs it and
# does the stdout capture itself, so what is proved here is the production path.
# $CH_SAY is printed on stdout; $CH_WRITE, when set, is copied into the outdir
# under $CH_WRITE_AS. Either, neither or both — that is the whole matrix.
ENG="$TMPROOT/engine"; mkdir -p "$ENG"
WORKER="$ENG/ev-worker"
cat >"$WORKER" <<'EVS'
#!/usr/bin/env bash
printf 'worker %s\n' "$#" >>"${CH_WORKER_LOG:-/dev/null}"
out="${LCARS_WORK_OUT:-}"
if [ -n "${CH_WRITE:-}" ] && [ -f "${CH_WRITE:-}" ] && [ -n "$out" ]; then
  cp "$CH_WRITE" "$out/${CH_WRITE_AS:-xo-verdict.json}"
fi
[ -n "${CH_SAY:-}" ] && [ -f "${CH_SAY:-}" ] && cat "$CH_SAY"
exit 0
EVS
chmod +x "$WORKER"

IN="$TMPROOT/in"; mkdir -p "$IN"
printf '%s\n' '{"productTypes": [{"type": "cli", "source": "the plan"}], "criteria": [{"id": "prd-1", "text": "relay file stores a record"}]}' \
  >"$IN/criteria.json"
printf '# the prd\n' >"$IN/prd.md"

spawn() { # <repo> <mission-id> <mode> <outdir>  (CH_* already exported)
  ( cd "$1" && LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$IN" \
      LCARS_GH_BIN=/usr/bin/true \
      bash "$RUNSH" spawn-number-one --mission "$2" --mode "$3" --outdir "$4" \
      >"$4.console" 2>&1 )
}

field() { # <json-file> <key> — a string field, or empty
  "$PY" -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit(0)
v = d.get(sys.argv[2])
print(v if isinstance(v, str) else "")' "$1" "$2" 2>/dev/null
}

# ===========================================================================
# 1. THE PROMPT ASKS FOR THE FRAME — a record, not an inference
# ===========================================================================
echo ""
echo "1. the prompt asks the worker to FRAME its file and NAME it"

repo0="$(new_repo repo0)"; m0="$(plant "$repo0" lcars-20261005-400)"
P0="$TMPROOT/prompt.txt"
PDUMP="$ENG/adapter-dump.sh"
cat >"$PDUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$PDUMP"
( cd "$repo0" && XO_PROMPT_DUMP="$P0" LCARS_WORKER_ADAPTER="$PDUMP" \
    LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=copilot \
    LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
    bash "$RUNSH" spawn-number-one --mission lcars-20261005-400 \
      --mode evaluate --outdir "$TMPROOT/p-out" >/dev/null 2>&1 )
check "1a. the prompt was captured at all" '[ -s "$P0" ]'
check "1b. THE BEHAVIOUR — it names the opening delimiter, with the filename in it" \
  'grep -qF "===LCARS-XO-BEGIN " "$P0"'
check "1b. …and the closing one" \
  'grep -qF "$END_MARK" "$P0"'
check "1c. it says the FILENAME goes on the opening line (so the harness never guesses)" \
  'tr "\n" " " <"$P0" | tr -s " " | grep -qi "name the file on that first line"'
check "1d. it says a turn with NEITHER the file NOR the frame is no output" \
  'tr "\n" " " <"$P0" | tr -s " " | grep -qi "neither the file nor a framed block"'
check "1e. CONTROL — the `answer` mode's prompt frames ITS file, not a verdict" \
  '( cd "$repo0" && XO_PROMPT_DUMP="$TMPROOT/prompt-answer.txt" \
       LCARS_WORKER_ADAPTER="$PDUMP" LCARS_WORKER_BIN="$WORKER" \
       LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
       LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
       bash "$RUNSH" spawn-number-one --mission lcars-20261005-400 \
         --mode answer --outdir "$TMPROOT/p-out2" >/dev/null 2>&1 );
   grep -qF "===LCARS-XO-BEGIN xo-answer.json===" "$TMPROOT/prompt-answer.txt"'

# ===========================================================================
# 2. A WORKER THAT ONLY SPEAKS — the harness writes its verdict
# ===========================================================================
echo ""
echo "2. no file, a framed verdict on stdout: the harness writes it"

SAY1="$ENG/say-verdict.txt"
{ printf 'I looked at the three shots and here is my judgement.\n\n'
  printf '%s\n' "$BEGIN_V"
  verdict_json met
  printf '%s\n' "$END_MARK"
  printf '\nThat is my verdict. I had no file-writing tool this turn.\n'
} >"$SAY1"

O1="$TMPROOT/out-1"
export CH_SAY="$SAY1"; unset CH_WRITE CH_WRITE_AS
spawn "$repo0" lcars-20261005-400 evaluate "$O1"
check "2a. THE BEHAVIOUR — xo-verdict.json exists although the worker wrote nothing" \
  '[ -s "$O1/xo-verdict.json" ]'
check "2b. …and it is the worker's own JSON, parseable and complete" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"score\"] == \"medium\", d.get(\"score\")
assert d[\"criteria\"][0][\"id\"] == \"prd-1\", d[\"criteria\"]
" "$O1/xo-verdict.json"'
check "2c. …and nothing of the surrounding prose came with it" \
  '! grep -qF "I had no file-writing tool" "$O1/xo-verdict.json" &&
   ! grep -qF "LCARS-XO-BEGIN" "$O1/xo-verdict.json"'
check "2d. RECORDED — the channel record says it arrived by stdout" \
  '[ -s "$O1/xo-channel.json" ] && [ "$(field "$O1/xo-channel.json" via)" = "stdout" ]'
check "2d. …and names the file it wrote" \
  '[ "$(field "$O1/xo-channel.json" file)" = "xo-verdict.json" ]'
check "2e. …and the console says so in a sentence a reader can follow" \
  'grep -qi "on stdout" "$O1.console"'

# ===========================================================================
# 3. CONTROL — a worker that DOES write the file keeps it, untouched
# ===========================================================================
echo ""
echo "3. CONTROL: the file a worker wrote itself is used, and its stdout is not consulted"

MINE="$ENG/written-by-worker.json"
verdict_json met | "$PY" -c 'import json,sys
d=json.load(sys.stdin)
d["summary"]="WRITTEN BY THE WORKER ITSELF."
json.dump(d, sys.stdout, indent=2)' >"$MINE"
SAY2="$ENG/say-other.txt"
{ printf 'and here it is again, in case you need it\n'
  printf '%s\n' "$BEGIN_V"
  verdict_json met | "$PY" -c 'import json,sys
d=json.load(sys.stdin)
d["summary"]="SPOKEN ON STDOUT — THIS MUST NOT WIN."
json.dump(d, sys.stdout, indent=2)'
  printf '\n%s\n' "$END_MARK"
} >"$SAY2"

O2="$TMPROOT/out-2"
export CH_SAY="$SAY2" CH_WRITE="$MINE" CH_WRITE_AS=xo-verdict.json
spawn "$repo0" lcars-20261005-400 evaluate "$O2"
check "3a. THE BEHAVIOUR — the worker's OWN file is the one on disk" \
  'grep -qF "WRITTEN BY THE WORKER ITSELF" "$O2/xo-verdict.json"'
check "3b. …and the spoken block did NOT overwrite it" \
  '! grep -qF "THIS MUST NOT WIN" "$O2/xo-verdict.json"'
check "3c. …byte for byte what the worker wrote" \
  'cmp -s "$MINE" "$O2/xo-verdict.json"'
check "3d. RECORDED — the channel record says it came from the worker's own file" \
  '[ "$(field "$O2/xo-channel.json" via)" = "worker-file" ]'
check "3d. …and names it" \
  '[ "$(field "$O2/xo-channel.json" file)" = "xo-verdict.json" ]'

# ===========================================================================
# 4. PROSE WITH NO FRAME — an honest failure that names what was missing
# ===========================================================================
echo ""
echo "4. prose and nothing else: an honest failure, naming what was missing"

SAY3="$ENG/say-prose.txt"
printf 'I looked at all three shots. The build looks broadly right to me, the\nheader is there and the add row reads well. Overall I would call it medium.\n' \
  >"$SAY3"
O3="$TMPROOT/out-3"
export CH_SAY="$SAY3"; unset CH_WRITE CH_WRITE_AS
spawn "$repo0" lcars-20261005-400 evaluate "$O3"
check "4a. no verdict file was invented out of the prose" \
  '[ ! -e "$O3/xo-verdict.json" ] && [ ! -e "$O3/xo-actions.json" ]'
check "4b. …and nothing crashed: the spawn still returned" \
  '[ -f "$O3/.worker.out" ]'
check "4c. RECORDED — the channel record says the answer never arrived" \
  '[ -s "$O3/xo-channel.json" ] && [ "$(field "$O3/xo-channel.json" via)" = "none" ]'
check "4d. THE BEHAVIOUR — the why NAMES the frame that was missing" \
  '"$PY" -c "
import sys
w=sys.argv[1]
assert \"===LCARS-XO-BEGIN\" in w, w
assert w.strip(), w
" "$(field "$O3/xo-channel.json" why)"'
check "4d. …and names the file it was waiting for" \
  'printf "%s" "$(field "$O3/xo-channel.json" why)" | grep -qF "xo-verdict.json"'
check "4e. …and it is a SENTENCE, not a token" \
  '[ "$(printf "%s" "$(field "$O3/xo-channel.json" why)" | wc -w | tr -d " ")" -ge 12 ]'

# ===========================================================================
# 5. A FRAME AROUND MALFORMED JSON — the same honest failure, naming that
# ===========================================================================
echo ""
echo "5. a framed block that is not JSON: said, not swallowed"

SAY4="$ENG/say-bad.txt"
{ printf 'here is my verdict\n'
  printf '%s\n' "$BEGIN_V"
  printf '{"score": "medium", "criteria": [ {"id": "prd-1",\n'
  printf '%s\n' "$END_MARK"
} >"$SAY4"
O4="$TMPROOT/out-4"
export CH_SAY="$SAY4"; unset CH_WRITE CH_WRITE_AS
spawn "$repo0" lcars-20261005-400 evaluate "$O4"
check "5a. no half-written verdict file reached disk" \
  '[ ! -e "$O4/xo-verdict.json" ]'
check "5b. RECORDED — via is none, not a silent empty verdict" \
  '[ "$(field "$O4/xo-channel.json" via)" = "none" ]'
check "5c. THE BEHAVIOUR — the why says the frame was there and its content was not JSON" \
  'printf "%s" "$(field "$O4/xo-channel.json" why)" | grep -qi "not valid json"'
check "5c. …and names the file the frame claimed to be" \
  'printf "%s" "$(field "$O4/xo-channel.json" why)" | grep -qF "xo-verdict.json"'
check "5d. CONTROL — the two failures do NOT read the same" \
  '[ "$(field "$O3/xo-channel.json" why)" != "$(field "$O4/xo-channel.json" why)" ]'

# AND AN UNCLOSED FRAME IS ITS OWN SENTENCE — a reply cut off mid-verdict.
SAY5="$ENG/say-unclosed.txt"
{ printf '%s\n' "$BEGIN_V"; verdict_json met; } >"$SAY5"
O5="$TMPROOT/out-5"
export CH_SAY="$SAY5"; unset CH_WRITE CH_WRITE_AS
spawn "$repo0" lcars-20261005-400 evaluate "$O5"
check "5e. an UNCLOSED frame is refused, and the why says it was never closed" \
  '[ ! -e "$O5/xo-verdict.json" ] &&
   [ "$(field "$O5/xo-channel.json" via)" = "none" ] &&
   printf "%s" "$(field "$O5/xo-channel.json" why)" | grep -qF "===LCARS-XO-END==="'

# ===========================================================================
# 6. THE FILENAME IS READ OFF THE FRAME, NEVER ASSUMED
# ===========================================================================
echo ""
echo "6. the worker names which of its two files it is handing over"

SAY6="$ENG/say-actions.txt"
{ printf 'I want another round.\n'
  printf '%s\n' "$BEGIN_A"
  printf '%s\n' '{"actions": [{"click": "#add"}, {"screenshot": "after-add"}]}'
  printf '%s\n' "$END_MARK"
} >"$SAY6"
O6="$TMPROOT/out-6"
export CH_SAY="$SAY6"; unset CH_WRITE CH_WRITE_AS
spawn "$repo0" lcars-20261005-400 evaluate "$O6"
check "6a. THE BEHAVIOUR — a framed xo-actions.json becomes xo-actions.json" \
  '[ -s "$O6/xo-actions.json" ]'
check "6b. …and NOT a verdict (the harness never decided which file this was)" \
  '[ ! -e "$O6/xo-verdict.json" ]'
check "6c. …and the record names the file the worker chose" \
  '[ "$(field "$O6/xo-channel.json" file)" = "xo-actions.json" ] &&
   [ "$(field "$O6/xo-channel.json" via)" = "stdout" ]'

# A FILE THIS ROUND MAY NOT WRITE IS REFUSED BY NAME.
SAY7="$ENG/say-wrong-name.txt"
{ printf '%s\n' '===LCARS-XO-BEGIN my-notes.json==='
  printf '%s\n' '{"score": "high"}'
  printf '%s\n' "$END_MARK"
} >"$SAY7"
O7="$TMPROOT/out-7"
export CH_SAY="$SAY7"; unset CH_WRITE CH_WRITE_AS
spawn "$repo0" lcars-20261005-400 evaluate "$O7"
check "6d. a frame naming a file this round may not write is refused, by name" \
  '[ ! -e "$O7/my-notes.json" ] &&
   [ "$(field "$O7/xo-channel.json" via)" = "none" ] &&
   printf "%s" "$(field "$O7/xo-channel.json" why)" | grep -qF "my-notes.json"'

# TWO FRAMES IS AMBIGUOUS, AND AMBIGUOUS IS SAID, NOT GUESSED.
SAY8="$ENG/say-two.txt"
{ printf '%s\n' "$BEGIN_V"; verdict_json met; printf '%s\n' "$END_MARK"
  printf '%s\n' "$BEGIN_A"; printf '%s\n' '{"actions": []}'; printf '%s\n' "$END_MARK"
} >"$SAY8"
O8="$TMPROOT/out-8"
export CH_SAY="$SAY8"; unset CH_WRITE CH_WRITE_AS
spawn "$repo0" lcars-20261005-400 evaluate "$O8"
check "6e. TWO framed files is refused — this round writes exactly one" \
  '[ ! -e "$O8/xo-verdict.json" ] && [ ! -e "$O8/xo-actions.json" ] &&
   [ "$(field "$O8/xo-channel.json" via)" = "none" ]'
check "6e. …and the why names both of them" \
  'printf "%s" "$(field "$O8/xo-channel.json" why)" | grep -qF "xo-verdict.json" &&
   printf "%s" "$(field "$O8/xo-channel.json" why)" | grep -qF "xo-actions.json"'

# ===========================================================================
# 7. END TO END — a look whose worker only ever SPEAKS still reaches a verdict
# ===========================================================================
echo ""
echo "7. a real \`xo.sh evaluate\` with a worker that has no write tool at all"

EVD="$TMPROOT/ev"; mkdir -p "$EVD"
export XO_LAUNCH_LOG="$EVD/launch.log"; : >"$XO_LAUNCH_LOG"
export XO_DRIVE_LOG="$EVD/drive.log";   : >"$XO_DRIVE_LOG"
LAUNCH_STUB="$EVD/launch.sh"
cat >"$LAUNCH_STUB" <<'LS'
#!/usr/bin/env bash
mid="$1"; shift
m="$PWD/.git/lcars/missions/$mid"
printf 'launch %s %s\n' "$mid" "$*" >>"$XO_LAUNCH_LOG"
case "${1:-}" in
  --stop) printf '{\n  "status": "stopped"\n}\n' >"$m/launch.json"; exit 0 ;;
esac
printf '{\n  "status": "running",\n  "url": "http://127.0.0.1:4310/",\n  "pid": 1\n}\n' >"$m/launch.json"
LS
chmod +x "$LAUNCH_STUB"
DRIVE_STUB="$EVD/drive.sh"
cat >"$DRIVE_STUB" <<'DS'
#!/usr/bin/env bash
printf 'drive %s\n' "$*" >>"$XO_DRIVE_LOG"
out=""
while [ $# -gt 0 ]; do
  case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"
n="$(ls "$out"/*.png 2>/dev/null | grep -c . | tr -d ' ')"
printf 'PNG\n' >"$out/shot-0$((n+1)).png"
printf '{"shot":"shot-0%s"}\n' "$((n+1))" >"$out/shot-0$((n+1)).json"
printf '{"url":"http://127.0.0.1:4310/","allPainted":true}\n'
exit 0
DS
chmod +x "$DRIVE_STUB"

# THE SPEAKING-ONLY WORKER. Every round, it says its verdict and writes nothing.
SPEAKER="$ENG/speaker"
cat >"$SPEAKER" <<EVS
#!/usr/bin/env bash
printf 'worker\n' >>"$EVD/speaker.log"
cat "$SAY1"
exit 0
EVS
chmod +x "$SPEAKER"
: >"$EVD/speaker.log"

repoE="$(new_repo repoE)"; mE="$(plant "$repoE" lcars-20261005-401)"
outE="$("$PY" "$CAGE" 600 bash -c '
  cd "$1" && LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" LCARS_NODE_BIN=bash \
    LCARS_WORKER_BIN="$4" LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_LOG_SCRIPT=/usr/bin/true LCARS_RESOLVE_LOGS_SCRIPT=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 LCARS_XO_UNLISTED=0 LCARS_XO_PRELAUNCH=0 \
    bash "$5" evaluate --mission lcars-20261005-401 2>&1' _ \
  "$repoE" "$LAUNCH_STUB" "$DRIVE_STUB" "$SPEAKER" "$XO")"
printf '%s\n' "$outE" >"$EVD/evaluate.out"
check "7a. the look ran at all — a worker was hired" \
  '[ -s "$EVD/speaker.log" ]'
check "7b. THE BEHAVIOUR — the look reached a SCORED verdict on a spoken file" \
  '[ -s "$mE/xo/verdict.json" ] &&
   ! grep -q "could not reach a verdict" "$mE/xo/verdict.json" &&
   ! grep -q "without reaching a verdict" "$mE/xo/verdict.json" &&
   "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"criteria\"), d
" "$mE/xo/verdict.json"'
check "7c. …and it is the ledger the worker SPOKE" \
  'grep -qF "I ran the CLI and read what it printed" "$mE/xo/verdict.json"'
check "7d. RECORDED IN THE LOOK — the journal says which path the verdict came by" \
  '"$PY" -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
got=[r for r in rows if r.get(\"action\") == \"verdict-channel\"]
assert got, sorted({r.get(\"action\") for r in rows})
assert got[-1].get(\"via\") == \"stdout\", got[-1]
" "$mE/number-one.jsonl"'
check "7e. …and the First Officer's report RENDERS it, so a reader can tell" \
  '( cd "$repoE" && "$PY" "$REPORT_PY" "$repoE/.git/lcars/missions" \
       "$TMPROOT/seen7.json" --all 2>&1 ) | grep -q "verdict-channel"'

# CONTROL — the SAME look with a worker that writes its own file records the
# other path, so the field is a fact about this look and not a constant.
WRITER="$ENG/writer"
cat >"$WRITER" <<EVS
#!/usr/bin/env bash
printf 'worker\n' >>"$EVD/writer.log"
cp "$MINE" "\${LCARS_WORK_OUT}/xo-verdict.json"
exit 0
EVS
chmod +x "$WRITER"
: >"$EVD/writer.log"
repoF="$(new_repo repoF)"; mF="$(plant "$repoF" lcars-20261005-402)"
"$PY" "$CAGE" 600 bash -c '
  cd "$1" && LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" LCARS_NODE_BIN=bash \
    LCARS_WORKER_BIN="$4" LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_LOG_SCRIPT=/usr/bin/true LCARS_RESOLVE_LOGS_SCRIPT=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 LCARS_XO_UNLISTED=0 LCARS_XO_PRELAUNCH=0 \
    bash "$5" evaluate --mission lcars-20261005-402 2>&1' _ \
  "$repoF" "$LAUNCH_STUB" "$DRIVE_STUB" "$WRITER" "$XO" >"$EVD/evaluate-writer.out" 2>&1
check "7f. CONTROL — a look whose worker wrote the file records \`worker-file\`" \
  '"$PY" -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
got=[r for r in rows if r.get(\"action\") == \"verdict-channel\"]
assert got, sorted({r.get(\"action\") for r in rows})
assert got[-1].get(\"via\") == \"worker-file\", got[-1]
" "$mF/number-one.jsonl"'
check "7f. …and that look also reached its verdict" \
  '[ -s "$mF/xo/verdict.json" ]'

# ===========================================================================
# 8. THE TOOL LISTS — copilot's names on 1.0.92, and the claude column untouched
# ===========================================================================
echo ""
echo "8. the tool lists: \`rg\` for the search tool, no write tool for number-one, claude unchanged"

# READ OFF THE REAL SEAM — the argv the adapter would actually spawn, never a
# grep of the table. The tool list is the token AFTER the cli's own list flag.
tools() { # <cli> <role>
  bash "$ADAPTER" argv "$1" "$2" "$TMPROOT/out-argv" 2>/dev/null | "$PY" -c '
import sys
flag = {"copilot": "--available-tools", "claude": "--allowedTools"}[sys.argv[1]]
rows = [l.rstrip("\n") for l in sys.stdin]
for i, r in enumerate(rows):
    if r == flag and i + 1 < len(rows):
        print(rows[i + 1]); break
' "$1"
}
NO="$(tools copilot number-one)"
check "8. the seam this section reads really does yield a list at all" \
  '[ -n "$NO" ] && [ -n "$(tools claude number-one)" ]'
check "8a. THE BEHAVIOUR — copilot's number-one role has \`rg\`" \
  '[ -n "$NO" ] && printf ",%s," "$NO" | grep -qF ",rg,"'
check "8b. …and not also \`grep\` — the older name for the SAME tool, so one, not both" \
  '! printf ",%s," "$NO" | grep -qF ",grep,"'
# S261 — THIS IS ABOUT THE PAPER-GATE ROLE, and stays true of it. The captain
# amended the S168 clause on 2026-10-08 (19:33 MDT): the VERIFY LOOK runs as the
# separate role `number-one-live`, which DOES get `bash`, contained by a
# disposable detached worktree instead (`lcars-xo-eyes`). This file's subject —
# the verdict CHANNEL — is unaffected either way: both roles still say their
# verdict in the frame and the harness still writes the file.
check "8c. …and no shell for the paper-gate role: \`number-one\` never gets \`bash\`" \
  '! printf ",%s," "$NO" | grep -qF ",bash,"'
check "8c2. …while the LOOK's role does, and still carries no write tool" \
  'printf ",%s," "$(tools copilot number-one-live)" | grep -qF ",bash," &&
   ! printf ",%s," "$(tools copilot number-one-live)" | grep -qF ",create,"'
check "8d. …nor \`edit\`" \
  '! printf ",%s," "$NO" | grep -qF ",edit,"'
check "8e. …and no \`create\` either — with the frame, it needs no write tool" \
  '! printf ",%s," "$NO" | grep -qF ",create,"'
check "8f. …it can still SEE: view and glob are both there" \
  'printf ",%s," "$NO" | grep -qF ",view," && printf ",%s," "$NO" | grep -qF ",glob,"'

# EVERY copilot ROLE loses `grep` for `rg` — a rename, nowhere half-applied.
for r in repo-read repo-read-web repo-write launch number-one number-one-live default; do
  t="$(tools copilot "$r")"
  check "8g. copilot/$r names no tool called \`grep\`" \
    '! printf ",%s," "$t" | grep -qF ",grep,"'
done
for r in repo-read repo-read-web repo-write launch; do
  t="$(tools copilot "$r")"
  check "8h. copilot/$r can search, with \`rg\`" \
    'printf ",%s," "$t" | grep -qF ",rg,"'
done
check "8i. and no READ role gained a shell on the way" \
  '! printf ",%s," "$(tools copilot repo-read)" | grep -qF ",bash," &&
   ! printf ",%s," "$(tools copilot repo-read-web)" | grep -qF ",bash," &&
   ! printf ",%s," "$(tools copilot launch)" | grep -qF ",bash,"'
check "8j. repo-write still has the shell it always had" \
  'printf ",%s," "$(tools copilot repo-write)" | grep -qF ",bash,"'

# THE CLAUDE COLUMN IS UNCHANGED — asserted as the exact literal lists.
check "8k. CONTROL — claude/number-one is byte-for-byte what it was" \
  '[ "$(tools claude number-one)" = "Read,Grep,Glob,Write" ]'
check "8k. …claude/repo-read too" \
  '[ "$(tools claude repo-read)" = "Read,Grep,Glob,Write" ]'
check "8k. …claude/repo-read-web too" \
  '[ "$(tools claude repo-read-web)" = "Read,Grep,Glob,Write,WebSearch,WebFetch" ]'
check "8k. …claude/repo-write too" \
  '[ "$(tools claude repo-write)" = "Read,Grep,Glob,Write,Edit,Bash" ]'
check "8k. …claude/launch too" \
  '[ "$(tools claude launch)" = "Read,Grep,Glob,Write" ]'
check "8k. …claude/default too" \
  '[ "$(tools claude default)" = "Read" ]'
check "8l. and the stale version claim is gone: the comment names what was verified" \
  '! grep -q "verified live against copilot v1.0.60" "$ADAPTER"'
check "8l. …and names 1.0.92, the build these names were re-measured on" \
  'grep -qF "1.0.92" "$ADAPTER"'

# THE ARGV THE WORKER IS ACTUALLY SPAWNED WITH carries the corrected list.
A8="$TMPROOT/argv-number-one.txt"
( cd "$repo0" && bash "$ADAPTER" argv copilot number-one "$TMPROOT/out-argv" ) >"$A8" 2>/dev/null
check "8m. the spawned argv's --available-tools is the corrected list" \
  'grep -A1 -- "--available-tools" "$A8" | tail -1 | grep -qF "rg" &&
   ! grep -A1 -- "--available-tools" "$A8" | tail -1 | grep -qE "(^|,)(grep|bash|create|edit)(,|$)"'

# ---------------------------------------------------------------------------
# 8n-8v. THE RECORD IS TRUE — the comments a future session will ACT on
# ---------------------------------------------------------------------------
# WHY A COMMENT NEEDS A TEST. The first cut of this round wrote a WRONG REASON
# into the source as dated, verified fact: that copilot had stopped registering
# `create`, that `grep` was dead, that `repo-read`/`repo-read-web`/`launch` were
# therefore "broken on copilot — a DECISION FOR A HUMAN", and — directly above
# S194's write-tool floor in run.sh — that the floor "may be guarding a hole that
# was never where it looked". A future session reads that and deletes the floor.
#
# IT WAS MEASURED ON COPILOT'S DEFAULT MODEL instead of the one LCARS sends.
# RE-MEASURED LIVE against /opt/homebrew/bin/copilot (self-reporting 1.0.92) BY
# ABSOLUTE PATH — `command -v copilot` on a dev machine resolves to VS Code's
# shim, which re-invokes `copilot` back off $PATH, so a "live" call lands in a
# fake; a counting fake sat first on $PATH for all four calls and stayed at ZERO:
#
#   --available-tools view,grep,glob,create, NO --model
#       → "Unable to create `nomodel.txt`: no file-writing tool is available",
#         and no file on disk.
#   the same list WITH --model claude-opus-4.8
#       → "Created `withmodel.txt` containing `OK`. I used the **create** tool."
#   view,grep WITH a model
#       → found the planted string: "I used the **grep** tool (ripgrep-based)".
#   view,rg,glob,create WITH a model
#       → searched AND wrote, first try.
#
# And `run.sh resolve-stage-model numberOne` on copilot prints
# `model=claude-opus-4.8`, so the production spawn DOES carry a model.
#
# SO: the tool set is MODEL-DEPENDENT; `create` and `grep` both exist on a model
# that offers them; there was no outage; and S194's floor — which is what puts
# the model on the argv — is exactly right. These checks pin that record, because
# prose is all that stands between the next session and removing the floor.
check "8n. the adapter does NOT claim copilot stopped registering \`create\`" \
  '! grep -qiE "create.? (NO LONGER EXISTS|no longer exists|is dead|does not exist)|STILL DEAD" "$ADAPTER"'
check "8o. …nor that any read role is BROKEN on copilot pending a human decision" \
  '! grep -qiE "broken on copilot|DECISION FOR A HUMAN" "$ADAPTER"'
check "8p. …and it RECORDS the real mechanism — the tool set is model-dependent" \
  'grep -qi "MODEL-DEPENDENT" "$ADAPTER" && grep -qF "claude-opus-4.8" "$ADAPTER"'
check "8q. …and that BOTH search names resolve, so the rename claims nothing more" \
  'grep -qi "both names resolve" "$ADAPTER"'
check "8r. …and it points at the S194 floor as the thing that supplies the model" \
  'grep -qF "S194" "$ADAPTER"'
check "8s. the S194 WRITE-TOOL FLOOR is still in run.sh, stated as the requirement" \
  'grep -qF "A COLD WORKER WHOSE CONTRACT IS TO WRITE A" "$RUNSH" &&
   grep -qF "write_capable_alias() {" "$RUNSH"'
check "8t. …and NOTHING above it tells a future session the floor may be pointless" \
  '! grep -qiE "guarding a hole|do not treat the inference as settled" "$RUNSH"'
check "8u. …instead run.sh records that the floor was RE-MEASURED and stands" \
  'grep -qi "MODEL-DEPENDENT" "$RUNSH" && grep -qi "DO NOT REMOVE THIS FLOOR" "$RUNSH"'
check "8v. the channel reader docstring invents no missing copilot tool" \
  '! grep -qiE "no longer exists|only general file-write path|is dead" \
       "$REPO_ROOT/skills/lcars-run/number-one-channel.py"'
check "8w. …nor does the verdict-channel block in run.sh blame a missing copilot tool" \
  '! grep -qiE "copilot 1\.0\.[0-9]+ (does not|no longer) register" "$RUNSH" &&
   ! grep -qiE "the only general file-write path" "$RUNSH"'

# ===========================================================================
# 9. THE LIVE CONTROL — one real, free copilot call through the corrected list
# ===========================================================================
echo ""
echo "9. live control: a real copilot worker searches and frames a verdict with no write tool"

if [ "${LCARS_XO_CHANNEL_LIVE:-0}" = "1" ] && [ -n "$REAL_COPILOT" ]; then
  SPEND_BEFORE="$(wc -l <"$SPEND_LOG" | tr -d ' ')"
  LIVE="$TMPROOT/live"; mkdir -p "$LIVE"
  printf 'the mix-ratio line is MISSING from this build\n' >"$LIVE/observations.txt"
  printf 'nothing to see here\n' >"$LIVE/decoy.txt"
  LTOOLS="$(tools copilot number-one)"
  # THE MODEL MATTERS, AND LEAVING IT OFF IS THE TRAP THAT MISREAD THIS WHOLE
  # ROUND: copilot's tool set is MODEL-DEPENDENT, so a call with no `--model`
  # exercises a DIFFERENT tool surface than the one a real spawn gets. run.sh
  # resolves `numberOne` on copilot to claude-opus-4.8 (S194's write-tool floor),
  # so the live control sends exactly that.
  LIVE_MODEL="$(LCARS_WORKER_BIN=copilot bash "$RUNSH" resolve-stage-model numberOne 2>/dev/null \
                 | sed -n 's/.*model=//p' | tail -1)"
  [ -n "$LIVE_MODEL" ] && [ "$LIVE_MODEL" != "-" ] || LIVE_MODEL=claude-opus-4.8
  LOUT="$TMPROOT/live.out"
  ( cd "$LIVE" && "$REAL_COPILOT" -p "Use your search tool to find which file in this directory contains the words 'mix-ratio line'. Then reply with exactly this, and nothing between the two marker lines but JSON:
${BEGIN_V}
{\"score\": \"low\", \"foundIn\": \"<the filename>\"}
${END_MARK}
Do not write any files." -s --model "$LIVE_MODEL" --available-tools "$LTOOLS" --allow-all-tools \
      --no-ask-user --disable-builtin-mcps --no-custom-instructions \
      --add-dir . ) >"$LOUT" 2>"$TMPROOT/live.err"
  check "9a. the live worker SEARCHED — it found the file, with rg and no shell" \
    'grep -qF "observations.txt" "$LOUT"'
  check "9b. …and it FRAMED its verdict exactly as the prompt asks" \
    'grep -qF "$BEGIN_V" "$LOUT" && grep -qF "$END_MARK" "$LOUT"'
  check "9c. …and the harness's own reader lifts a valid file out of that reply" \
    '"$PY" "$REPO_ROOT/skills/lcars-run/number-one-channel.py" "$LOUT" \
        "$TMPROOT/live-out" xo-verdict.json xo-actions.json >/dev/null 2>&1 &&
     "$PY" -c "import json,sys; json.load(open(sys.argv[1]))" "$TMPROOT/live-out/xo-verdict.json"'
  check "9d. …and it wrote NO file of its own (there was no tool to do it with)" \
    '[ "$(ls "$LIVE" | wc -l | tr -d " ")" = "2" ]'
  check "9e. …and the live call really did reach the REAL cli, not this file's shim" \
    '[ "$(wc -l <"$SPEND_LOG" | tr -d " ")" = "$SPEND_BEFORE" ]'
  printf '  the live control ran: %s\n' "$REAL_COPILOT"
  printf '  its reply:\n'; sed "s/^/    | /" "$LOUT"
elif [ "${LCARS_XO_CHANNEL_LIVE:-0}" = "1" ]; then
  skip "9. live control asked for, but no \`copilot\` on PATH to run it with"
else
  skip "9. live control SKIPPED — set LCARS_XO_CHANNEL_LIVE=1 to make one real (free) copilot call"
fi

printf '\n  \033[1m%d pass, %d fail\033[0m\n' "$pass" "$fail"
SPEND="$(wc -l <"$SPEND_LOG" | tr -d ' ')"
MODELED="$(grep -c -- '--model' "$SPEND_LOG" 2>/dev/null || true)"
printf '  shim invocations: %s (with --model: %s)\n' "$SPEND" "${MODELED:-0}"
check "ZERO SPEND — no faked engine CLI was ever invoked" '[ "$SPEND" = "0" ]'
[ "$SPEND" = "0" ] || sed 's/^/    shim| /' "$SPEND_LOG"
printf '\nlcars-xo-verdict-channel: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
