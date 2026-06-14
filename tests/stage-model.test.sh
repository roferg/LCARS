#!/usr/bin/env bash
#
# Tests for the PER-STAGE worker-model resolver (skills/lcars-run/run.sh,
# session 58). This generalizes the single global $WORKER_MODEL into a per-stage
# SELECTION: each headless stage (research, validate, plan, planReview, implement)
# may be assigned its own model from a declarative source (estimate.json), while
# emitting BYTE-IDENTICAL argv to the legacy global path whenever no per-stage
# source is present.
#
# Resolution precedence for a stage key (highest first):
#   a. $LCARS_WORKER_MODEL env       — global pin, wins for ALL stages (verbatim)
#   b. estimate.json models.<key>    — a logical tier (sonnet/opus) → alias-mapped
#   c. config.json stages.<key>.model — logical tier → alias-mapped
#   d. config.json workerModel       — global, verbatim flag (back-compat)
#   e. unset                         — empty (NO --model flag at all)
#
# Per-CLI alias map (logical tier → that CLI's flag string), config-overridable
# via config.json modelAliases.<cli>.<tier>:
#   claude  → { sonnet: "sonnet",  opus: "opus" }
#   copilot → { sonnet: "",        opus: "claude-opus-4.8" }
#
# Two seams are exercised:
#   * the mission-free `resolve-stage-model <key>` subcommand, which prints
#       STAGE-MODEL key=<k> model=<flag|->
#     so resolution can be asserted without an LLM or a real mission; and
#   * the REAL stub-captured argv via the worker spawn chokepoint, driven by the
#     `spawn-stage <role>` test subcommand which calls worker_spawn through a
#     recording stub binary — proving the model flag actually reaches the adapter
#     argv (what the external tester checks).
#
# ⚠ This session's ambient env may have CLAUDECODE=1 set; every invocation scrubs
# the host markers + worker env explicitly so a default/legacy assertion can never
# pass for the wrong reason.
#
# Usage: bash tests/stage-model.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/skills/lcars-run/run.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# A recording stub CLI: writes its full argv (one arg per line) to $STUB_ARGV.
make_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
: >"$STUB_ARGV"
for a in "$@"; do printf '%s\n' "$a" >>"$STUB_ARGV"; done
exit 0
EOF
  chmod +x "$1"
}

# Build a throwaway repo with a .git/lcars/config.json (+ optional estimate.json
# for a synthetic mission "M58"). $1 = config body, $2 = estimate body (optional).
make_repo() { # config-json  [estimate-json]
  local d; d="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$d" && git init -q )
  mkdir -p "$d/.git/lcars/missions/M58"
  printf '%s\n' "${1:-{\}}" >"$d/.git/lcars/config.json"
  # A minimal state.json so locate_mission accepts the mission.
  printf '{ "id": "M58" }\n' >"$d/.git/lcars/missions/M58/state.json"
  if [ "$#" -ge 2 ]; then
    printf '%s\n' "$2" >"$d/.git/lcars/missions/M58/estimate.json"
  fi
  printf '%s' "$d"
}

# resolve-stage-model: print the resolved flag for a stage KEY, mission-free but
# estimate-aware (it reads $MISSION_DIR/estimate.json when --mission is given).
# Scrubs host markers; caller re-sets via leading VAR=val tokens.
rsm() { # repo  key  [extra env...]
  local repo="$1" key="$2"; shift 2
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_CLI -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      "$@" bash "$RUN" resolve-stage-model --mission M58 "$key" 2>/dev/null )
}

# spawn-stage: drive the REAL worker_spawn chokepoint for a given env ROLE through
# a recording stub, then return the captured argv. Proves the model flag lands in
# the actual spawned argv (the path the tester verifies).
spawn_argv() { # repo  role  [extra env...]
  local repo="$1" role="$2"; shift 2
  local stub="$repo/stub-cli"; make_stub "$stub"
  local argv="$repo/stub.argv"
  ( cd "$repo" && STUB_ARGV="$argv" env -u CLAUDECODE \
      -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      "$@" STUB_ARGV="$argv" \
      LCARS_WORKER_BIN="$stub" LCARS_WORKER_CLI=claude \
      bash "$RUN" spawn-stage --mission M58 "$role" >/dev/null 2>&1 )
  cat "$argv" 2>/dev/null
}

# Pull the token following --model from a captured argv (empty if absent).
model_of() { awk '/^--model$/{getline; print; exit}'; }
# Pull the resolved flag from a `STAGE-MODEL key=<k> model=<flag|->` line. A bare
# `-` (the unset sentinel) reads as empty so the legacy assertions stay clean.
sm_model() { sed -En 's/.*model=(.*)$/\1/p' | sed 's/^-$//'; }

echo "stage-model — per-stage worker-model resolver (session 58)"

EST='{"models":{"research":"opus","validate":"sonnet","plan":"sonnet","planReview":"opus","implement":"opus","verify":"sonnet"}}'

# === Behavior 1: estimate.json drives each stage to its tier's claude flag =====
r1="$(make_repo '{}' "$EST")"
check "1a. research → opus (estimate)"      "[ \"\$(rsm \"$r1\" research CLAUDECODE=1 | sm_model)\" = 'opus' ]"
check "1b. validate → sonnet (estimate)"    "[ \"\$(rsm \"$r1\" validate CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"
check "1c. plan → sonnet (estimate)"        "[ \"\$(rsm \"$r1\" plan CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"
check "1d. planReview → opus (estimate)"    "[ \"\$(rsm \"$r1\" planReview CLAUDECODE=1 | sm_model)\" = 'opus' ]"
check "1e. implement → opus (estimate)"     "[ \"\$(rsm \"$r1\" implement CLAUDECODE=1 | sm_model)\" = 'opus' ]"

# And the SAME via the real spawned argv (role → stage key → flag), through stub.
check "1f. spawn research-questions argv carries --model opus" \
  "[ \"\$(spawn_argv \"$r1\" research-questions CLAUDECODE=1 | model_of)\" = 'opus' ]"
check "1g. spawn validate argv carries --model sonnet" \
  "[ \"\$(spawn_argv \"$r1\" validate CLAUDECODE=1 | model_of)\" = 'sonnet' ]"
check "1h. spawn plan-review argv carries --model opus" \
  "[ \"\$(spawn_argv \"$r1\" plan-review CLAUDECODE=1 | model_of)\" = 'opus' ]"
check "1i. spawn implement-implementer argv carries --model opus" \
  "[ \"\$(spawn_argv \"$r1\" implement-implementer CLAUDECODE=1 | model_of)\" = 'opus' ]"

# === Behavior 2: NO estimate, no per-stage config, no env ⇒ NO --model anywhere
r2="$(make_repo '{}')"   # no estimate.json passed
for k in research validate plan planReview implement; do
  check "2.$k resolve-stage-model emits NO --model (legacy)" \
    "[ -z \"\$(rsm \"$r2\" $k CLAUDECODE=1 | sm_model)\" ]"
done
for role in research-questions research-agent validate plan plan-review \
            implement-test-writer implement-implementer context-pack; do
  check "2.argv $role has ZERO --model tokens (byte-identical legacy)" \
    "[ -z \"\$(spawn_argv \"$r2\" $role CLAUDECODE=1 | grep -x -- --model)\" ]"
done

# === Behavior 3: LCARS_WORKER_MODEL env pins EVERY stage, beats estimate.json ==
r3="$(make_repo '{}' "$EST")"
for k in research validate plan planReview implement; do
  check "3.$k env pin ⇒ opus regardless of estimate" \
    "[ \"\$(rsm \"$r3\" $k CLAUDECODE=1 LCARS_WORKER_MODEL=opus | sm_model)\" = 'opus' ]"
done
check "3.argv env pin reaches spawned validate argv as opus (beats estimate sonnet)" \
  "[ \"\$(spawn_argv \"$r3\" validate CLAUDECODE=1 LCARS_WORKER_MODEL=opus | model_of)\" = 'opus' ]"

# === Behavior 4: config workerModel (global, verbatim) applies to every stage ==
r4="$(make_repo '{"workerModel": "sonnet"}')"   # no estimate.json
for k in research validate plan planReview implement; do
  check "4.$k global workerModel ⇒ sonnet flag" \
    "[ \"\$(rsm \"$r4\" $k CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"
done
check "4.argv global workerModel reaches spawned plan argv" \
  "[ \"\$(spawn_argv \"$r4\" plan CLAUDECODE=1 | model_of)\" = 'sonnet' ]"

# === Behavior 5: copilot active ⇒ tier 'opus' translates to claude-opus-4.8 ====
r5="$(make_repo '{}' "$EST")"
check "5a. copilot opus tier → claude-opus-4.8 (resolve-stage-model)" \
  "[ \"\$(rsm \"$r5\" research COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
# S59 spike: the copilot Sonnet tier now resolves to claude-sonnet-4.6 (was an
# empty placeholder). validate is tier 'sonnet' in $EST, so it must map to that.
check "5b. copilot sonnet tier → claude-sonnet-4.6 (resolve-stage-model)" \
  "[ \"\$(rsm \"$r5\" validate COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-sonnet-4.6' ]"

# === Bonus: config stages.<key>.model (precedence c) translates per tier =======
r6="$(make_repo '{"stages":{"plan":{"model":"opus"}}}')"   # no estimate.json
check "6a. config stages.plan.model=opus ⇒ opus flag" \
  "[ \"\$(rsm \"$r6\" plan CLAUDECODE=1 | sm_model)\" = 'opus' ]"
check "6b. config stages.plan only affects plan, not validate (legacy elsewhere)" \
  "[ -z \"\$(rsm \"$r6\" validate CLAUDECODE=1 | sm_model)\" ]"
check "6c. estimate.json overrides config stages.<key>.model (precedence b > c)" \
  "[ \"\$(rsm \"$(make_repo '{\"stages\":{\"plan\":{\"model\":\"opus\"}}}' \"$EST\")\" plan CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"

# === Bonus: infra (context-pack) is NOT escalated by estimate.json =============
r7="$(make_repo '{}' "$EST")"
check "7a. context-pack (infra) argv carries NO --model despite estimate.json" \
  "[ -z \"\$(spawn_argv \"$r7\" context-pack CLAUDECODE=1 | grep -x -- --model)\" ]"

# === Session 62: captain model override (state.json modelOverride / env) ======
# Precedence (highest first):
#   a.  $LCARS_WORKER_MODEL env        — global pin, verbatim, wins everywhere
#   a2. $LCARS_MODEL_OVERRIDE env      — scope:tier; env path wins over persisted
#   a3. state.json modelOverride       — { scope, tier }; same precedence band
#   b.  estimate.json models.<key>     — for stages OUTSIDE the override scope
#   c.  config stages.<key>.model …
# Axes: reasoning = research,validate,plan,planReview ; implementation = implement,verify.
# The override stores a LOGICAL TIER, translated through the SAME alias map.

# Set state.json modelOverride = { scope, tier } on a repo's M58 mission.
set_override() { # repo scope tier
  printf '{\n  "id": "M58",\n  "modelOverride": { "scope": "%s", "tier": "%s" }\n}\n' \
    "$2" "$3" >"$1/.git/lcars/missions/M58/state.json"
}

# --- Behavior 8: state.json modelOverride scope=all pins EVERY stage ----------
# Even when the estimate.json is sonnet-heavy, all/opus forces opus everywhere.
r8="$(make_repo '{}' "$EST")"; set_override "$r8" all opus
for k in research validate plan planReview implement verify; do
  check "8.$k all:opus override beats estimate ⇒ opus" \
    "[ \"\$(rsm \"$r8\" $k CLAUDECODE=1 | sm_model)\" = 'opus' ]"
done
check "8.argv spawn research-questions carries --model opus (all override)" \
  "[ \"\$(spawn_argv \"$r8\" research-questions CLAUDECODE=1 | model_of)\" = 'opus' ]"
check "8.argv spawn implement-implementer carries --model opus (all override)" \
  "[ \"\$(spawn_argv \"$r8\" implement-implementer CLAUDECODE=1 | model_of)\" = 'opus' ]"

# --- Behavior 9: scope=implementation pins implement+verify only -------------
# implement/verify → opus; the reasoning axis still follows estimate.json.
r9="$(make_repo '{}' "$EST")"; set_override "$r9" implementation opus
check "9a. implement (in scope) ⇒ opus override" \
  "[ \"\$(rsm \"$r9\" implement CLAUDECODE=1 | sm_model)\" = 'opus' ]"
check "9b. verify (in scope) ⇒ opus override" \
  "[ \"\$(rsm \"$r9\" verify CLAUDECODE=1 | sm_model)\" = 'opus' ]"
# Out of scope ⇒ estimate.json values (validate=sonnet, planReview=opus in \$EST).
check "9c. validate (out of scope) still follows estimate ⇒ sonnet" \
  "[ \"\$(rsm \"$r9\" validate CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"
check "9d. research (out of scope) still follows estimate ⇒ opus" \
  "[ \"\$(rsm \"$r9\" research CLAUDECODE=1 | sm_model)\" = 'opus' ]"
check "9e. argv spawn validate (out of scope) still --model sonnet" \
  "[ \"\$(spawn_argv \"$r9\" validate CLAUDECODE=1 | model_of)\" = 'sonnet' ]"

# --- Behavior 10: scope=reasoning pins the reasoning axis only ---------------
# research,validate,plan,planReview → sonnet; implement still follows estimate (opus).
r10="$(make_repo '{}' "$EST")"; set_override "$r10" reasoning sonnet
for k in research validate plan planReview; do
  check "10.$k reasoning:sonnet override ⇒ sonnet" \
    "[ \"\$(rsm \"$r10\" $k CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"
done
check "10.implement (out of scope) still follows estimate ⇒ opus" \
  "[ \"\$(rsm \"$r10\" implement CLAUDECODE=1 | sm_model)\" = 'opus' ]"

# --- Behavior 11: LCARS_WORKER_MODEL env STILL beats a persisted override -----
r11="$(make_repo '{}' "$EST")"; set_override "$r11" all sonnet
check "11. env LCARS_WORKER_MODEL=opus beats persisted all:sonnet override" \
  "[ \"\$(rsm \"$r11\" implement CLAUDECODE=1 LCARS_WORKER_MODEL=opus | sm_model)\" = 'opus' ]"

# --- Behavior 12: LCARS_MODEL_OVERRIDE env, NO state.json override -----------
r12="$(make_repo '{}' "$EST")"   # state.json is just { id } — no modelOverride
for k in research validate plan planReview implement verify; do
  check "12.$k LCARS_MODEL_OVERRIDE=all:opus pins every stage" \
    "[ \"\$(rsm \"$r12\" $k CLAUDECODE=1 LCARS_MODEL_OVERRIDE=all:opus | sm_model)\" = 'opus' ]"
done
check "12.argv spawn plan carries --model opus (env override)" \
  "[ \"\$(spawn_argv \"$r12\" plan CLAUDECODE=1 LCARS_MODEL_OVERRIDE=all:opus | model_of)\" = 'opus' ]"

# --- Behavior 13: env LCARS_MODEL_OVERRIDE wins over persisted modelOverride --
r13="$(make_repo '{}' "$EST")"; set_override "$r13" all sonnet
check "13. env override implementation:opus beats persisted all:sonnet (implement)" \
  "[ \"\$(rsm \"$r13\" implement CLAUDECODE=1 LCARS_MODEL_OVERRIDE=implementation:opus | sm_model)\" = 'opus' ]"
# A stage outside the ENV override scope falls to the estimate (env override
# REPLACES the persisted one entirely — same env-over-persisted rule as the model).
check "13. reasoning stage under env implementation override falls to estimate (validate=sonnet)" \
  "[ \"\$(rsm \"$r13\" validate CLAUDECODE=1 LCARS_MODEL_OVERRIDE=implementation:opus | sm_model)\" = 'sonnet' ]"

# --- Behavior 14: copilot adapter emits the right --model under an override ---
# opus → claude-opus-4.8 ; sonnet → claude-sonnet-4.6 (the S59 alias-map default).
r14="$(make_repo '{}' "$EST")"; set_override "$r14" all opus
check "14a. copilot all:opus override ⇒ claude-opus-4.8 (resolve-stage-model)" \
  "[ \"\$(rsm \"$r14\" implement COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
# Spawn the REAL chokepoint as copilot (a dedicated invocation — the shared
# spawn_argv helper force-pins claude, so we drive worker_spawn directly here with
# LCARS_WORKER_CLI=copilot so the copilot adapter's --model lands in the argv).
spawn_argv_copilot() { # repo role override
  local repo="$1" role="$2" ov="$3"
  local stub="$repo/stub-cli2"; make_stub "$stub"
  local argv="$repo/stub2.argv"
  ( cd "$repo" && env -u CLAUDECODE -u COPILOT_CLI \
      COPILOT_RUN_APP=1 STUB_ARGV="$argv" \
      LCARS_MODEL_OVERRIDE="$ov" \
      LCARS_WORKER_BIN="$stub" LCARS_WORKER_CLI=copilot \
      bash "$RUN" spawn-stage --mission M58 "$role" >/dev/null 2>&1 )
  cat "$argv" 2>/dev/null
}
check "14b. copilot all:opus override reaches spawned argv as claude-opus-4.8" \
  "[ \"\$(spawn_argv_copilot \"$r14\" implement-implementer all:opus | model_of)\" = 'claude-opus-4.8' ]"
r14b="$(make_repo '{}' "$EST")"
check "14c. copilot env reasoning:sonnet override ⇒ claude-sonnet-4.6" \
  "[ \"\$(rsm \"$r14b\" plan COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_MODEL_OVERRIDE=reasoning:sonnet | sm_model)\" = 'claude-sonnet-4.6' ]"

# --- Behavior 15: infra (context-pack) is NEVER touched by an override --------
# It short-circuits to the global/legacy value, exactly like the estimate path.
r15="$(make_repo '{}' "$EST")"; set_override "$r15" all opus
check "15. context-pack (infra) argv carries NO --model despite all:opus override" \
  "[ -z \"\$(spawn_argv \"$r15\" context-pack CLAUDECODE=1 | grep -x -- --model)\" ]"

# --- Behavior 16: override never leaks onto the LEGACY path -------------------
# No override + no estimate + no env ⇒ still NO --model anywhere (S58 parity).
r16="$(make_repo '{}')"   # no estimate, state.json = { id }
for k in research validate plan planReview implement verify; do
  check "16.$k no override / no estimate ⇒ still NO --model (legacy parity)" \
    "[ -z \"\$(rsm \"$r16\" $k CLAUDECODE=1 | sm_model)\" ]"
done

echo "stage-model: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
