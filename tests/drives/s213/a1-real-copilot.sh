#!/usr/bin/env bash
#
# A1 — PROVED AGAINST THE REAL COPILOT CLI, not a stub.
#
# The claim: with a context pack present, a Copilot worker STARTS. It does not
# die at argument parsing.
#
# A stub would fake the exact layer that broke, so nothing here is stubbed on the
# path that matters: the grant is computed by the SHIPPED run.sh helper against a
# real git repo with a real mission and a real context pack, the argv is built by
# the SHIPPED worker-adapter, and the binary on the other end is the real
# /opt/homebrew/bin/copilot.
#
# It runs in two halves, and BOTH have to land or the run proves nothing:
#   CONTROL  the pre-fix shape — the pack granted as a FILE — must still DIE at
#            argv-parse with "Not a directory". Without this the PASS half only
#            shows that copilot works, not that this was ever broken.
#   PASS     the shipped shape — the real grant, pack included — must START and
#            come back with the worker's own artifact on disk.
#
# Usage: bash tests/drives/s213/a1-real-copilot.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"
ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"
COPILOT="${LCARS_REAL_COPILOT:-/opt/homebrew/bin/copilot}"
MID="lcars-20260917-001"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

[ -x "$COPILOT" ] || { echo "no real copilot at $COPILOT — cannot prove A1"; exit 2; }
echo "A1 — real copilot: $("$COPILOT" --version 2>&1 | head -1)"

WORK="${LCARS_A1_WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORK"
printf '  work dir (kept, for reading the raw transcripts): %s\n' "$WORK"

# --- a real repo, a real mission, a real context pack ----------------------
REPO="$WORK/repo"; mkdir -p "$REPO"
(
  cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t
  mkdir -p src && printf 'base\n' >src/base.txt && git add -A && git commit -q -m init
  git checkout -q -b "lcars/$MID" && printf 'm\n' >src/m.txt && git add -A && git commit -q -m mission
  git checkout -q main
) >/dev/null 2>&1
mkdir -p "$REPO/.git/lcars/missions/$MID" "$REPO/.git/lcars/context"
printf '{ "projectName": "a1-fixture" }\n' >"$REPO/.git/lcars/config.json"
cat >"$REPO/.git/lcars/missions/$MID/state.json" <<JSON
{ "id": "$MID", "type": "feature", "title": "t", "stage": "align",
  "branch": "lcars/$MID", "base": "main", "githubIssue": null }
JSON
printf '# Mission\n\n**Goal:** something.\n' >"$REPO/.git/lcars/missions/$MID/prd.md"
# THE PACK IS AN ORDINARY CONTEXT PACK, because the question we put to the
# worker has to be an ordinary question.
#
# The first version of this probe planted a codeword and asked the worker to
# echo it back. That reads like secret-extraction, and a model declining it is
# reasonable behaviour, not a broken grant — measured: it answered "I'm sorry,
# but I cannot assist with that request" on 3 of 4 spins, and the one spin that
# complied is what a single sample bought. A model's output is a lottery.
#
# So the pack says what a real pack says, and the question is the one every
# front-half Stage actually asks: ground yourself in this repo. Nothing here is
# a secret, so there is nothing to decline — while the ANSWER still cannot be
# produced without having read through the grant, because the project, its
# stack and its layout exist nowhere else on this machine.
cat >"$REPO/.git/lcars/context/context-pack.md" <<'PACK'
# Repo context

**Project:** Thornbury Tide Tables — a public tide-time board for a small harbour.

**Stack:** Elixir 1.16 with Phoenix LiveView, Postgres 16.

**Layout:**
- `lib/thornbury/` — the tide model and the harbour calendar.
- `lib/thornbury_web/live/` — the LiveView surface the public sees.

**Test command:** `mix test`

**Conventions:** every tide reading is stored in UTC and rendered in the
harbour's local time; the board never shows a reading older than six hours.
PACK
PACK="$REPO/.git/lcars/context/context-pack.md"

# --- the grant, computed by the SHIPPED helper (not hand-typed) ------------
# A recording adapter captures exactly what run.sh exported, the same way
# tests/worker-fence.test.sh reads it.
cat >"$WORK/rec-adapter.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "argv" ] || [ "${1:-}" = "spawn" ]; then
  printf 'input_dirs=%s\n' "$(printf '%s' "${LCARS_WORKER_INPUT_DIRS:-}" | tr '\n' '|')" >>"$RECORD"
fi
exit 96
EOF
chmod +x "$WORK/rec-adapter.sh"
printf '#!/usr/bin/env bash\nexit 96\n' >"$WORK/worker"; chmod +x "$WORK/worker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/gh"; chmod +x "$WORK/gh"
: >"$WORK/record"
( cd "$REPO" && env LCARS_GH_BIN="$WORK/gh" LCARS_WORKER_BIN="$WORK/worker" \
    LCARS_WORKER_ADAPTER="$WORK/rec-adapter.sh" LCARS_WORKER_CLI=copilot \
    LCARS_VERSION_CHECK=0 RECORD="$WORK/record" \
    bash "$RUN_SH" research --mission "$MID" ) >/dev/null 2>&1
GRANT="$(sed -n 's/^input_dirs=//p' "$WORK/record" | head -1 | tr '|' '\n' | sed '/^$/d')"
printf '  grant the shipped run.sh produced:\n'; printf '    %s\n' $GRANT

if printf '%s\n' "$GRANT" | grep -qxF "$REPO/.git/lcars/context"; then
  ok "A1-0  the grant names the pack's own directory (a real run.sh, a real repo)"
else
  bad "A1-0  the grant does NOT name the pack's directory — got: $GRANT"
fi

spawn() { # <outdir> <grant-lines> <prompt>  → writes out/err, echoes rc
  local out="$1" grant="$2" prompt="$3"
  mkdir -p "$out"
  LCARS_WORKER_BIN="$COPILOT" LCARS_WORKER_INPUT_DIRS="$grant" \
    bash "$ADAPTER" spawn copilot repo-read "$out" "$prompt" \
    >"$out/stdout.txt" 2>"$out/stderr.txt"
  echo $?
}

# --- CONTROL: the CLI contract itself, probed directly ---------------------
# Probed against the real binary, NOT through the adapter — the adapter now
# refuses to build such an argv, which is the fix, so asking it to would prove
# nothing. Both halves matter: the FILE must be refused (this was ever broken)
# and a DIRECTORY must get past that same parse (copilot is not simply down).
printf '\n  -- CONTROL: what the real CLI does with --add-dir --\n'
"$COPILOT" -p "hi" --add-dir "$PACK" >"$WORK/ctl-file.out" 2>"$WORK/ctl-file.err"
if grep -qi 'not a directory' "$WORK/ctl-file.out" "$WORK/ctl-file.err"; then
  ok "A1-C1 the real copilot REFUSES a file to --add-dir, before the model runs"
  printf '        %s\n' "$(cat "$WORK/ctl-file.out" "$WORK/ctl-file.err" | grep -i -m1 'not a directory')"
else
  bad "A1-C1 the control did NOT reproduce the refusal — this run proves nothing"
  head -3 "$WORK/ctl-file.out" "$WORK/ctl-file.err"
fi
"$COPILOT" -p "hi" --add-dir "$(dirname "$PACK")" --this-flag-does-not-exist \
  >"$WORK/ctl-dir.out" 2>"$WORK/ctl-dir.err"
if grep -qi 'not a directory' "$WORK/ctl-dir.out" "$WORK/ctl-dir.err"; then
  bad "A1-C2 a DIRECTORY was refused too — the refusal is not about files at all"
else
  ok "A1-C2 …while the pack's DIRECTORY gets past that parse (it fails later, on a flag that really is bogus)"
fi

# --- PASS: the shipped grant, pack present, must START and REACH the pack ---
# The prompt asks for the one word that exists ONLY inside the granted
# directory, so the answer is proof the grant reached the file — not just that
# the process survived its own arguments. (A repo-read worker holds no pen on
# copilot, so the proof is what it SAYS, captured in the worker sidecar the
# adapter writes; asking it to create a file would be testing the wrong thing.)
printf '\n  -- the shipped path: real run.sh grant, real adapter, real copilot --\n'
OUT="$WORK/live"
PRC="$(spawn "$OUT" "$GRANT" "Read the repo context file at EXACTLY this path: $PACK
Then, in one short sentence, tell me what this project is called and what it is for.")"
SAID="$(cat "$OUT/.worker.out" "$OUT/stdout.txt" 2>/dev/null)"
if printf '%s' "$SAID" | grep -qi 'not a directory'; then
  bad "A1-1  the worker STILL died at argv-parse"
  sed -n '1,5p' "$OUT/stderr.txt"
else
  ok "A1-1  the worker STARTED with a context pack present — no argv-parse refusal (rc=$PRC)"
fi
if [ -s "$OUT/.worker.out" ]; then
  ok "A1-2  …it ran a turn and came back with a transcript ($(wc -c <"$OUT/.worker.out" | tr -d ' ') bytes)"
else
  bad "A1-2  …but it came back with nothing at all (rc=$PRC)"
fi
# The answer has to turn on CONTENT that exists only inside the granted
# directory — the project's name, or its domain together with its stack. None of
# it is on this machine anywhere else, so an answer carrying it is an answer that
# came through the grant. Matched loosely on purpose: we are checking that it
# READ the thing, not that it phrased its reply any particular way.
LOW="$(printf '%s' "$SAID" | tr '[:upper:]' '[:lower:]')"
if printf '%s' "$LOW" | grep -q 'thornbury' \
   || { printf '%s' "$LOW" | grep -q 'tide' \
        && printf '%s' "$LOW" | grep -qE 'elixir|phoenix|liveview|harbour|harbor'; }; then
  ok "A1-3  …and it READ THE PACK through the grant — its answer carries facts held only in that file"
  printf '        %s\n' "$(printf '%s' "$SAID" | tr -d '\r' | grep -v '^[[:space:]]*$' | head -2 | cut -c1-140)"
else
  bad "A1-3  …it did not read the pack through the grant. It said:"
  sed -n '1,6p' "$OUT/.worker.out" 2>/dev/null
fi

printf '\nA1 real-copilot drive: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
