#!/usr/bin/env bash
#
# Tests for cold-worker BINARY + MODEL resolution (skills/lcars-run/run.sh,
# session 19). This is the CLI-agnostic seam: run.sh decides WHICH cli to run as
# the cold worker (and with which model), the adapter (worker-adapter.sh) decides
# the cli-specific flags. Resolution precedence:
#
#   worker bin   : $LCARS_WORKER_BIN  >  the MISSION's recorded workerBin
#                  >  config.json workerBin
#                  >  host-CLI auto-detect (env marker)  >  claude (default)
#   worker model : $LCARS_WORKER_MODEL >  config.json workerModel  >  unset
#
# S196 A3 — THE MISSION NOW OUTRANKS config.json, and that is a REVERSAL. Until
# this session the clone's config sat above the mission's own pin, so a mission
# FILED on copilot and adopted onto a laptop whose config said claude ran on
# CLAUDE, silently: measured in S191's capstone with shims faking both engines —
# 3 invocations of the BILLED shim, 0 of the free one, no warning anywhere. The
# engine is now an EXPLICIT CHOICE MADE AT THE HANDOFF (`lcars adopt` asks and
# converts, and RECORDS the answer on the mission), and a recorded choice must
# beat an ambient repo default or the asking was theatre. $LCARS_WORKER_BIN — a
# per-invocation, deliberate operator act — still outranks everything.
#
# Host markers (the env var a process LCARS spawns inherits from its host CLI):
#   CLAUDECODE=1  ⇒ claude
#   COPILOT_RUN_APP=1 OR COPILOT_CLI_BINARY_VERSION=<non-empty>  ⇒ copilot
#   (the real GitHub Copilot CLI v1.0.60 sets COPILOT_RUN_APP=1 +
#    COPILOT_CLI_BINARY_VERSION + COPILOT_LOADER_PID; it does NOT set COPILOT_CLI)
#
# The resolver is exercised through the `resolve-worker` subcommand, which prints
# ONE self-explaining line naming the resolved cli + model + the winning SOURCE
# (env / config / detected / default), then a machine-readable summary so the
# tests can assert the resolved values without parsing prose:
#
#   WORKER-RESOLVED bin=<basename> binsrc=<src> model=<m|-> modelsrc=<src>
#
# ⚠ This session's ambient env has CLAUDECODE=1 set. Every test below controls
# the markers explicitly (env -u / explicit set) so a default/detect test can
# never pass for the wrong reason.
#
# Usage: bash tests/worker-resolve.test.sh
set -uo pipefail

# qgrep: drain stdin FULLY before grepping. A piped `grep -q` short-circuits on
# its first match and closes the pipe; a still-writing upstream producer then
# takes SIGPIPE and exits non-zero, and under `set -o pipefail` that flips a
# genuine match into a phantom assertion failure (timing/load-sensitive — it bit
# the worker-prompt assertions only under the full back-to-back suite). Draining
# first removes the race; exit status and output are otherwise identical to grep.
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/skills/lcars-run/run.sh"
ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# THE PARSE GUARD. S196 A3 makes the resolver WRITE to state.json (it records the
# engine it resolved and where that came from), and run.sh's field writer is the
# copy-pasted one that re-inserts after line 1 with a hard-coded comma. A text
# assertion cannot see the trailing comma that makes an object invalid — the exact
# class of defect S189's 100-check suite sailed past — so every claim about a
# written field goes THROUGH a real JSON parser.
jok()  { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); sys.stdout.write("" if v is None else str(v))' "$1" "$2" 2>/dev/null; }
command -v python3 >/dev/null 2>&1 || {
  echo "  python3 is REQUIRED by this suite — it is the only assertion that can see"
  echo "  invalid JSON, and the resolver now writes to state.json."
  exit 1
}

# Build a throwaway git repo with a .git/lcars/config.json so the resolver's
# config-path resolution (git-common-dir → .git/lcars/config.json) finds it.
# $1 = optional config.json body (default: an empty-object config).
make_repo() { # [config-json]
  local d; d="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$d" && git init -q )
  mkdir -p "$d/.git/lcars"
  printf '%s\n' "${1:-{\}}" >"$d/.git/lcars/config.json"
  printf '%s' "$d"
}

# Run `resolve-worker` from inside a repo with FULL control of the host markers.
# CLAUDECODE and ALL the copilot markers are scrubbed first; the caller re-sets
# via leading VAR=val tokens. Returns the WORKER-RESOLVED summary (stdout) AND the
# human resolution log line (stderr, merged in) so both surfaces are assertable.
resolve_in() { # repo  [extra env assignments...]
  local repo="$1"; shift
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_CLI -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      -u LCARS_WORKER_BIN_INTERNAL \
      "$@" bash "$RUN" resolve-worker 2>&1 )
}

echo "worker-resolve — host-default cold-worker bin + model (session 19)"

# --- 1. explicit LCARS_WORKER_BIN beats config AND detection ------------------
r1="$(make_repo '{"workerBin": "from-config-bin"}')"
out1="$(resolve_in "$r1" CLAUDECODE=1 LCARS_WORKER_BIN=/usr/bin/explicit-bin)"
check "1a. explicit env bin wins over config + detection" \
  "printf '%s' \"\$out1\" | qgrep -q 'bin=explicit-bin'"
check "1b. explicit env bin source = env" \
  "printf '%s' \"\$out1\" | qgrep -q 'binsrc=env'"

# --- 2. no env → config.json workerBin is used --------------------------------
r2="$(make_repo '{"workerBin": "config-bin"}')"
out2="$(resolve_in "$r2" CLAUDECODE=1)"
check "2a. config workerBin used when no env" \
  "printf '%s' \"\$out2\" | qgrep -q 'bin=config-bin'"
check "2b. config bin source = config" \
  "printf '%s' \"\$out2\" | qgrep -q 'binsrc=config'"

# --- 3. no env, no config → host marker resolves the cli ----------------------
r3="$(make_repo)"
out3c="$(resolve_in "$r3" CLAUDECODE=1)"
check "3a. CLAUDECODE marker ⇒ claude" \
  "printf '%s' \"\$out3c\" | qgrep -q 'bin=claude'"
check "3b. claude marker source = detected" \
  "printf '%s' \"\$out3c\" | qgrep -q 'binsrc=detected'"
# Real Copilot CLI (v1.0.60) sets COPILOT_RUN_APP=1 — NOT COPILOT_CLI.
out3p="$(resolve_in "$r3" COPILOT_RUN_APP=1)"
check "3c. COPILOT_RUN_APP marker ⇒ copilot" \
  "printf '%s' \"\$out3p\" | qgrep -q 'bin=copilot'"
check "3d. copilot marker source = detected" \
  "printf '%s' \"\$out3p\" | qgrep -q 'binsrc=detected'"
# Fallback marker: COPILOT_CLI_BINARY_VERSION non-empty (RUN_APP unset) ⇒ copilot.
out3v="$(resolve_in "$r3" COPILOT_CLI_BINARY_VERSION=1.0.60)"
check "3e. COPILOT_CLI_BINARY_VERSION marker ⇒ copilot" \
  "printf '%s' \"\$out3v\" | qgrep -q 'bin=copilot'"
check "3f. copilot version-marker source = detected" \
  "printf '%s' \"\$out3v\" | qgrep -q 'binsrc=detected'"

# --- 3g. THE MISSION'S OWN PIN BEATS HOST DETECTION --------------------------
# A mission records the engine it was filed with (`lcars file --engine copilot`)
# in state.json. The resolver used to skip straight from config to host
# auto-detect, so the engine was re-DECIDED from the ambient terminal on every
# invocation: a copilot mission RESUMED from a Claude Code session (CLAUDECODE=1)
# silently re-homed onto billed claude mid-flight, pin ignored. Observed live —
# 7 workers, $11.39 on the wrong engine, and the SPEND was the only symptom.
# An explicitly recorded engine must beat a guess.
# ONE FIELD PER LINE, exactly as file.sh's write_state emits it — the shape every
# state writer in LCARS edits as lines. S196: the resolver now WRITES here, so a
# fixture in a shape no real state.json has would prove nothing about the writer.
make_mission() { # repo  id  workerBin
  mkdir -p "$1/.git/lcars/missions/$2"
  cat >"$1/.git/lcars/missions/$2/state.json" <<JSON
{
  "id": "$2",
  "stage": "implement",
  "workerBin": "$3",
  "base": "main"
}
JSON
}
# A mission that records NO engine of its own — the fall-through fixture.
mk_nopin() { # repo
  mkdir -p "$1/.git/lcars/missions/m-nopin"
  printf '{\n  "id": "m-nopin",\n  "stage": "implement",\n  "base": "main"\n}\n' \
    >"$1/.git/lcars/missions/m-nopin/state.json"
}

resolve_mission_in() { # repo  mission-id  [env...]
  local repo="$1" mid="$2"; shift 2
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_CLI -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      -u LCARS_WORKER_BIN_INTERNAL \
      "$@" bash "$RUN" resolve-worker --mission "$mid" 2>&1 )
}

r3m="$(make_repo)"                       # NO config workerBin
make_mission "$r3m" m-pin copilot
out3m="$(resolve_mission_in "$r3m" m-pin CLAUDECODE=1)"
check "3g. a copilot-pinned mission resolved from a CLAUDE host ⇒ copilot" \
  "printf '%s' \"\$out3m\" | qgrep -q 'bin=copilot'"
check "3h. the winning source is the mission pin, not detection" \
  "printf '%s' \"\$out3m\" | qgrep -q 'binsrc=mission'"
check "3i. it did NOT silently re-home onto the host cli" \
  "! printf '%s' \"\$out3m\" | qgrep -q 'bin=claude'"

# S196 A3 — THE MISSION'S PIN NOW OUTRANKS config.json. (Before this session the
# assertion here was the opposite: "3j. config.json still OUTRANKS the mission
# pin". It was wrong in the only way that costs money — see the header.)
r3mc="$(make_repo '{"workerBin": "config-bin"}')"
make_mission "$r3mc" m-pin copilot
out3mc="$(resolve_mission_in "$r3mc" m-pin CLAUDECODE=1)"
check "3j. the mission's recorded engine OUTRANKS config.json workerBin" \
  "printf '%s' \"\$out3mc\" | qgrep -q 'bin=copilot' && printf '%s' \"\$out3mc\" | qgrep -q 'binsrc=mission'"
check "3j2. the clone's config does NOT silently re-home the mission" \
  "! printf '%s' \"\$out3mc\" | qgrep -q 'bin=config-bin'"
out3me="$(resolve_mission_in "$r3m" m-pin CLAUDECODE=1 LCARS_WORKER_BIN=/usr/bin/explicit-bin)"
check "3k. \$LCARS_WORKER_BIN still OUTRANKS the mission pin" \
  "printf '%s' \"\$out3me\" | qgrep -q 'binsrc=env'"

# config.json is still consulted for a mission that records NO engine of its own
# — the reversal moves the mission ABOVE config, it does not remove config.
r3mc2="$(make_repo '{"workerBin": "config-bin"}')"
mk_nopin "$r3mc2"
out3mc2="$(resolve_mission_in "$r3mc2" m-nopin CLAUDECODE=1)"
check "3j3. an unpinned mission still takes config.json workerBin" \
  "printf '%s' \"\$out3mc2\" | qgrep -q 'bin=config-bin' && printf '%s' \"\$out3mc2\" | qgrep -q 'binsrc=config'"

# --- 3m. THE PROVENANCE IS RECORDED, NOT RE-DERIVED --------------------------
# S196 A3(g). The `worker: … (bin: config)` line printed ZERO times during a real
# 6-stage auto-advance run (it only prints on --step), was persisted NOWHERE, and
# never reached the viewscreen — so "which engine ran, and why" was unanswerable
# after the fact. The RESOLVER now records the pair (engineResolved +
# engineSource) on the mission AT THE MOMENT IT RESOLVES. That is the round's
# infer-vs-record rule: the producer records; nobody re-reads config later and
# guesses which source won (the mistake S147/S156/S188 each paid rounds for).
r3p="$(make_repo '{"workerBin": "config-bin"}')"
make_mission "$r3p" m-pin copilot
out3p="$(resolve_mission_in "$r3p" m-pin CLAUDECODE=1)"
s3p="$r3p/.git/lcars/missions/m-pin/state.json"
check "3m. the resolution PERSISTS the engine it resolved" \
  "[ \"\$(jget '$s3p' engineResolved)\" = 'copilot' ]"
check "3n. and WHERE it came from" \
  "[ \"\$(jget '$s3p' engineSource)\" = 'mission' ]"
check "3o. state.json is still VALID JSON after the resolver wrote to it" \
  "jok '$s3p'"
check "3p. and the mission's own recorded workerBin is untouched" \
  "[ \"\$(jget '$s3p' workerBin)\" = 'copilot' ]"
# A resolution that did NOT come from the mission is recorded just as plainly.
r3q="$(make_repo '{"workerBin": "config-bin"}')"
mk_nopin "$r3q"
resolve_mission_in "$r3q" m-nopin CLAUDECODE=1 >/dev/null
s3q="$r3q/.git/lcars/missions/m-nopin/state.json"
check "3q. a config-sourced resolution records source=config" \
  "[ \"\$(jget '$s3q' engineSource)\" = 'config' ] && [ \"\$(jget '$s3q' engineResolved)\" = 'config-bin' ]"
check "3r. that state.json PARSES too" "jok '$s3q'"

# --- 3s. LCARS RE-PINNING A MISSION'S *OWN* ENGINE IS NOT A NEW REASON -------
# S196 fix round. `lcars approve` pins the mission engine for its reconcile leg
# (`export LCARS_WORKER_BIN="$engine"`, approve.sh) so a copilot mission heals on
# copilot instead of host-detecting claude. That pin is CORRECT and stays. What
# was wrong is what the recorder then made of it: an env var won the precedence
# race, so `engineSource` was rewritten `adopt-chosen` → `env` and the card's
# provenance line went from `copilot · chosen at adopt` to `copilot · $LCARS_WORKER_BIN`.
# Measured three separate times in one day's live runs (S196 capstone,
# tests/drives/s196-capstone/missionA-timeline.md).
#
# PROVENANCE ANSWERS "WHY DOES THIS MISSION RUN ON THIS ENGINE". LCARS
# re-asserting the mission's OWN recorded engine across a process boundary is not
# a new reason — it is the same reason, said again — so it must not overwrite the
# more specific truth (adopt-chosen / adopt-converted / the mission's own pin).
#
# THE PRODUCER RECORDS IT. approve does not leave the recorder to infer "this env
# value happens to equal the mission's workerBin, so it was probably me" — that is
# the inference this round's standing rule forbids (S147/S156/S188 each paid fix
# rounds for it). approve STATES it, by exporting $LCARS_WORKER_BIN_INTERNAL=1
# alongside the pin. The resolver reads the statement: an INTERNAL pin is not an
# operator act, so it does not claim the `env` source — the ladder carries on and
# the mission's own pin wins, exactly as it would have with no pin at all.
mk_adopted() { # repo  id  workerBin  engineSource
  mkdir -p "$1/.git/lcars/missions/$2"
  cat >"$1/.git/lcars/missions/$2/state.json" <<JSON
{
  "id": "$2",
  "stage": "verify",
  "workerBin": "$3",
  "engineResolved": "$3",
  "engineSource": "$4",
  "base": "main"
}
JSON
}
# The house field-writer re-inserts after line 1, so `base` must still be the LAST
# key after any write — the one shape that writer breaks on.
jlast() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.stdout.write(list(d.keys())[-1] if d else "")' "$1" 2>/dev/null; }

# 3s/3t — the HEADLINE, at the resolver: approve's internal pin over a mission the
# captain chose the engine for at adopt.
r3s="$(make_repo '{"workerBin": "config-bin"}')"
mk_adopted "$r3s" m-adopt copilot adopt-chosen
s3s="$r3s/.git/lcars/missions/m-adopt/state.json"
out3s="$(resolve_mission_in "$r3s" m-adopt CLAUDECODE=1 \
           LCARS_WORKER_BIN=copilot LCARS_WORKER_BIN_INTERNAL=1)"
check "3s. an INTERNAL pin resolves the SAME engine (the pin still works)" \
  "printf '%s' \"\$out3s\" | qgrep -q 'bin=copilot'"
check "3s2. …but it does NOT claim the env source — the mission's pin does" \
  "printf '%s' \"\$out3s\" | qgrep -q 'binsrc=mission'"
check "3t. the captain's answer at the adopt prompt SURVIVES approve's pin" \
  "[ \"\$(jget '$s3s' engineSource)\" = 'adopt-chosen' ]"
check "3t2. and the engine it names is unchanged" \
  "[ \"\$(jget '$s3s' engineResolved)\" = 'copilot' ]"
check "3t3. state.json is still VALID JSON" "jok '$s3s'"
check "3t4. and \`base\` is still the LAST field" "[ \"\$(jlast '$s3s')\" = 'base' ]"

# 3u — the --engine conversion path records `adopt-converted`; same rule.
r3u="$(make_repo '{"workerBin": "config-bin"}')"
mk_adopted "$r3u" m-conv claude adopt-converted
s3u="$r3u/.git/lcars/missions/m-conv/state.json"
resolve_mission_in "$r3u" m-conv COPILOT_RUN_APP=1 \
  LCARS_WORKER_BIN=claude LCARS_WORKER_BIN_INTERNAL=1 >/dev/null
check "3u. an adopt CONVERSION survives the internal pin too" \
  "[ \"\$(jget '$s3u' engineSource)\" = 'adopt-converted' ]"
check "3u2. that state.json PARSES" "jok '$s3u'"

# 3v — THE CURE MUST NOT BLIND THE RECORDER. A real $LCARS_WORKER_BIN, typed by
# the captain in his own shell, carries NO internal marker and still records
# `env` — even over an adopt record, because then the adopt record is no longer
# what happened.
r3v="$(make_repo '{"workerBin": "config-bin"}')"
mk_adopted "$r3v" m-adopt copilot adopt-chosen
s3v="$r3v/.git/lcars/missions/m-adopt/state.json"
out3v="$(resolve_mission_in "$r3v" m-adopt CLAUDECODE=1 LCARS_WORKER_BIN=claude)"
check "3v. a GENUINE external env var still wins the resolution" \
  "printf '%s' \"\$out3v\" | qgrep -q 'binsrc=env' && printf '%s' \"\$out3v\" | qgrep -q 'bin=claude'"
check "3v2. …and is still RECORDED as env (the env source stays recordable)" \
  "[ \"\$(jget '$s3v' engineSource)\" = 'env' ]"
check "3v3. the recorded engine follows it" \
  "[ \"\$(jget '$s3v' engineResolved)\" = 'claude' ]"

# 3w — a plain mission PIN with no adopt anywhere (the third live sighting: an
# `lcars file --engine copilot` mission, $LCARS_WORKER_BIN unset in every shell,
# recorded `env` after approve and approve printed `worker: copilot (bin: env)`).
r3w="$(make_repo)"
make_mission "$r3w" m-pin copilot
s3w="$r3w/.git/lcars/missions/m-pin/state.json"
out3w="$(resolve_mission_in "$r3w" m-pin CLAUDECODE=1 \
           LCARS_WORKER_BIN=copilot LCARS_WORKER_BIN_INTERNAL=1)"
check "3w. a plain mission pin re-asserted internally records \`mission\`, not env" \
  "[ \"\$(jget '$s3w' engineSource)\" = 'mission' ]"
check "3w2. the printed line AGREES with what was persisted" \
  "printf '%s' \"\$out3w\" | qgrep -q 'bin: mission'"
check "3w3. it never says the env pinned it" \
  "! printf '%s' \"\$out3w\" | qgrep -q 'bin: env'"
check "3w4. state.json PARSES and \`base\` is last" \
  "jok '$s3w' && [ \"\$(jlast '$s3w')\" = 'base' ]"

# 3x — DEGRADATION: an internal pin whose mission records no engine of its own.
# Unreachable from approve (it only pins what it read off the mission), but if it
# ever happens the ENGINE must not move — an internal pin is still a pin. Only
# the attribution degrades, honestly, to env.
r3x="$(make_repo '{"workerBin": "config-bin"}')"
mk_nopin "$r3x"
out3x="$(resolve_mission_in "$r3x" m-nopin CLAUDECODE=1 \
           LCARS_WORKER_BIN=copilot LCARS_WORKER_BIN_INTERNAL=1)"
check "3x. an internal pin on an unpinned mission still fixes the ENGINE" \
  "printf '%s' \"\$out3x\" | qgrep -q 'bin=copilot'"
check "3x2. it does NOT fall through to config.json and move the engine" \
  "! printf '%s' \"\$out3x\" | qgrep -q 'bin=config-bin'"

# A mission with NO recorded engine must fall through to detection UNCHANGED.
r3mn="$(make_repo)"
mk_nopin "$r3mn"
out3mn="$(resolve_mission_in "$r3mn" m-nopin COPILOT_RUN_APP=1)"
check "3l. a mission with no pin still falls through to host detection" \
  "printf '%s' \"\$out3mn\" | qgrep -q 'binsrc=detected'"

# --- 4. nothing at all → claude default (NO marker set) -----------------------
r4="$(make_repo)"
out4="$(resolve_in "$r4")"   # CLAUDECODE/COPILOT_CLI scrubbed by resolve_in
check "4a. no env, no config, no marker ⇒ claude" \
  "printf '%s' \"\$out4\" | qgrep -q 'bin=claude'"
check "4b. fallback source = default" \
  "printf '%s' \"\$out4\" | qgrep -q 'binsrc=default'"

# --- 5. workerModel: env > config > unset; unset ⇒ adapter emits NO --model ----
r5e="$(make_repo '{"workerModel": "config-model"}')"
out5e="$(resolve_in "$r5e" CLAUDECODE=1 LCARS_WORKER_MODEL=env-model)"
check "5a. env model wins over config" \
  "printf '%s' \"\$out5e\" | qgrep -q 'model=env-model'"
check "5b. env model source = env" \
  "printf '%s' \"\$out5e\" | qgrep -q 'modelsrc=env'"

r5c="$(make_repo '{"workerModel": "config-model"}')"
out5c="$(resolve_in "$r5c" CLAUDECODE=1)"
check "5c. config model used when no env" \
  "printf '%s' \"\$out5c\" | qgrep -q 'model=config-model'"
check "5d. config model source = config" \
  "printf '%s' \"\$out5c\" | qgrep -q 'modelsrc=config'"

r5u="$(make_repo)"
out5u="$(resolve_in "$r5u" CLAUDECODE=1)"
check "5e. no model anywhere ⇒ model unset (printed as -)" \
  "printf '%s' \"\$out5u\" | qgrep -q 'model=- '"

# Adapter regression lock: with NO model env, claude argv is byte-for-byte the
# session-18 five lines (no --model).
A_NOMODEL="$(env -u LCARS_WORKER_MODEL bash "$ADAPTER" argv claude repo-read "$TMPROOT")"
EXPECT_NOMODEL='-p
--allowedTools
Read,Grep,Glob,Write
--output-format
text'
check "5f. adapter: unset model ⇒ exactly the session-18 5 lines (no --model)" \
  "[ \"\$A_NOMODEL\" = \"\$EXPECT_NOMODEL\" ]"

# With a model env set, the adapter appends --model <m> for claude.
A_MODEL="$(LCARS_WORKER_MODEL=opus-x bash "$ADAPTER" argv claude repo-read "$TMPROOT")"
check "5g. adapter: set model ⇒ argv appends '--model'" \
  "printf '%s' \"\$A_MODEL\" | qgrep -qx -- '--model'"
check "5h. adapter: set model ⇒ argv appends the model value" \
  "printf '%s' \"\$A_MODEL\" | qgrep -qx 'opus-x'"
check "5i. adapter: --model is the LAST flag pair (appended, not reordered)" \
  "[ \"\$(printf '%s' \"\$A_MODEL\" | sed -n '6p')\" = '--model' ] && [ \"\$(printf '%s' \"\$A_MODEL\" | sed -n '7p')\" = 'opus-x' ]"

# --- 6. the resolution log line names the winning SOURCE for a human ----------
check "6a. log line names env source" \
  "printf '%s' \"\$out1\" | qgrep -qi 'env'"
check "6b. log line names config source" \
  "printf '%s' \"\$out2\" | qgrep -qi 'config'"
check "6c. log line names detected source" \
  "printf '%s' \"\$out3c\" | qgrep -qi 'detect'"
check "6d. log line names default source" \
  "printf '%s' \"\$out4\" | qgrep -qi 'default'"

echo "worker-resolve: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
