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
#   claude  → { sonnet: "sonnet",            opus: "opus" }
#   copilot → { sonnet: "claude-opus-4.8",   opus: "claude-opus-4.8" }
# S78: copilot is OPUS-SAFE by default — BOTH tiers map to claude-opus-4.8
# (its create-tool can't overwrite on a non-opus tier → Implement breaks). Still
# config-overridable via modelAliases.copilot.<tier>.
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
check "1i. spawn implement-tdd argv carries --model opus" \
  "[ \"\$(spawn_argv \"$r1\" implement-tdd CLAUDECODE=1 | model_of)\" = 'opus' ]"

# === Behavior 2: NO estimate, no per-stage config, no env ⇒ NO --model anywhere
r2="$(make_repo '{}')"   # no estimate.json passed
for k in research validate plan planReview implement; do
  check "2.$k resolve-stage-model emits NO --model (legacy)" \
    "[ -z \"\$(rsm \"$r2\" $k CLAUDECODE=1 | sm_model)\" ]"
done
for role in research-questions research-agent validate plan plan-review \
            implement-tdd context-pack; do
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

# === Behavior 5: copilot active ⇒ OPUS-SAFE — every tier resolves to opus ======
# S78: copilot is opus-safe BY DEFAULT (copilot's create-tool can't overwrite on
# a non-opus tier → Implement breaks), so BOTH the opus AND the sonnet tier map
# to claude-opus-4.8. Claude keeps its dynamic per-stage mix (sonnet→sonnet).
r5="$(make_repo '{}' "$EST")"
check "5a. copilot opus tier → claude-opus-4.8 (resolve-stage-model)" \
  "[ \"\$(rsm \"$r5\" research COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
# S78 opus-safe default: the copilot Sonnet tier now ALSO resolves to
# claude-opus-4.8. validate is tier 'sonnet' in $EST, so it maps to opus.
check "5b. copilot sonnet tier → claude-opus-4.8 (opus-safe default)" \
  "[ \"\$(rsm \"$r5\" validate COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"

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
check "8.argv spawn implement-tdd carries --model opus (all override)" \
  "[ \"\$(spawn_argv \"$r8\" implement-tdd CLAUDECODE=1 | model_of)\" = 'opus' ]"

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
# S78 opus-safe: opus → claude-opus-4.8 ; sonnet → claude-opus-4.8 (both tiers).
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
  "[ \"\$(spawn_argv_copilot \"$r14\" implement-tdd all:opus | model_of)\" = 'claude-opus-4.8' ]"
r14b="$(make_repo '{}' "$EST")"
# S78 opus-safe default: the sonnet tier of an override maps to claude-opus-4.8
# under copilot too (per-engine alias mapping of the override tier).
check "14c. copilot env reasoning:sonnet override ⇒ claude-opus-4.8 (opus-safe)" \
  "[ \"\$(rsm \"$r14b\" plan COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_MODEL_OVERRIDE=reasoning:sonnet | sm_model)\" = 'claude-opus-4.8' ]"

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

# === Behavior 17 (S78): per-mission engine resolves its OWN complete model set =
# ONE estimate, two engines: copilot is opus-safe on EVERY stage (its create-tool
# can't overwrite on a non-opus tier → Implement breaks), while claude keeps the
# estimate's per-stage tiers. The policy has ONE home (alias_for_tier's copilot
# default); it stays modelAliases.copilot.*-overridable. No daemon-wide pin.

# A sonnet-heavy estimate: validate/plan/implement/verify are sonnet tier.
EST_SONNET='{"models":{"research":"opus","validate":"sonnet","plan":"sonnet","planReview":"opus","implement":"sonnet","verify":"sonnet"}}'

# 17.1 — same estimate, both engines: copilot opus-safe, claude keeps tiers.
r17="$(make_repo '{}' "$EST_SONNET")"
check "17.1a copilot sonnet-tier stage → claude-opus-4.8 (opus-safe off one estimate)" \
  "[ \"\$(rsm \"$r17\" implement COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
check "17.1b SAME estimate on claude → sonnet (dynamic per-stage mix preserved)" \
  "[ \"\$(rsm \"$r17\" implement CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"
check "17.1c copilot opus-tier stage → claude-opus-4.8 (research)" \
  "[ \"\$(rsm \"$r17\" research COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"

# 17.2 — opus-safe is the DEFAULT: a freshly-inited config ({}, NO modelAliases).
r17b="$(make_repo '{}' "$EST_SONNET")"   # config is bare {}
check "17.2 copilot opus-safe with NO modelAliases configured (the default)" \
  "[ \"\$(rsm \"$r17b\" validate COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"

# 17.3 — config override STILL wins: modelAliases.copilot.sonnet beats the default.
r17c="$(make_repo '{"modelAliases":{"copilot":{"sonnet":"claude-sonnet-4.6"}}}' "$EST_SONNET")"
check "17.3 modelAliases.copilot.sonnet override wins over opus-safe default" \
  "[ \"\$(rsm \"$r17c\" validate COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-sonnet-4.6' ]"

# 17.4 — captain override all:sonnet: copilot still opus-safe, claude → sonnet.
r17d="$(make_repo '{}' "$EST_SONNET")"; set_override "$r17d" all sonnet
check "17.4a copilot all:sonnet override ⇒ claude-opus-4.8 (opus-safe of the tier)" \
  "[ \"\$(rsm \"$r17d\" implement COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
check "17.4b claude all:sonnet override ⇒ sonnet (per-engine alias of the tier)" \
  "[ \"\$(rsm \"$r17d\" implement CLAUDECODE=1 | sm_model)\" = 'sonnet' ]"

# === Behavior 18 (S194): THE WRITE-TOOL FLOOR for a worker that MUST write =====
# MEASURED on the real copilot binary (v1.0.60), every other flag identical to
# what LCARS sends (`--available-tools view,grep,glob,create --allow-all-tools
# --no-ask-user --disable-builtin-mcps`):
#     no --model                 -> NO FILE ("no write-capable tool was available")
#     no --model + --add-dir     -> NO FILE   (--add-dir is not the variable)
#     --model claude-opus-4.8    -> FILE WRITTEN
# The context-pack worker's ENTIRE contract is to write ONE file, and `infra` is
# deliberately excluded from the estimate/override/stage ladder — so nothing
# could ever give it a model and it silently produced nothing on copilot, which
# killed `run.sh implement` at resolve_context_source. The cure is a FLOOR at
# precedence (e): the ladder is UNCHANGED (7a/15/2.argv still hold), but where it
# yields nothing a write-contract stage takes the active CLI's write-capable
# alias. Empty for claude (its default model has Write) => argv byte-identical.
r18="$(make_repo '{}')"   # bare config, NO estimate, NO override — the live case
check "18a. copilot context-pack argv CARRIES --model claude-opus-4.8 (write floor)" \
  "[ \"\$(spawn_argv_copilot \"$r18\" context-pack '' | model_of)\" = 'claude-opus-4.8' ]"
check "18b. claude context-pack argv still carries NO --model (floor is empty there)" \
  "[ -z \"\$(spawn_argv \"$r18\" context-pack CLAUDECODE=1 | grep -x -- --model)\" ]"
# The floor is the SAME alias map S78 owns, so it stays config-overridable.
r18b="$(make_repo '{"modelAliases":{"copilot":{"opus":"claude-opus-4.9"}}}')"
check "18c. modelAliases.copilot.opus overrides the write floor" \
  "[ \"\$(rsm \"$r18b\" infra COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.9' ]"
# Precedence: the floor is the LAST resort — (a) env pin and (d) config
# workerModel both still win, verbatim, exactly as before.
r18c="$(make_repo '{"workerModel":"claude-sonnet-4.6"}')"
check "18d. config workerModel (d) still beats the floor (e)" \
  "[ \"\$(rsm \"$r18c\" infra COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-sonnet-4.6' ]"
check "18e. env LCARS_WORKER_MODEL pin still beats the floor" \
  "[ \"\$(rsm \"$r18\" infra COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_WORKER_MODEL=zzz | sm_model)\" = 'zzz' ]"
# AND the exclusion itself is INTACT: the floor is not a back door onto the
# escalation ladder. config stages.infra.model would resolve to claude-sonnet-4.6
# if (c) applied to infra; it must not — infra still short-circuits, and the
# floor (not the ladder) is what supplies the value.
r18d="$(make_repo '{"stages":{"infra":{"model":"sonnet"}},"modelAliases":{"copilot":{"sonnet":"claude-sonnet-4.6"}}}' "$EST")"
check "18f. stages.infra.model is STILL ignored (infra off the ladder; floor wins)" \
  "[ \"\$(rsm \"$r18d\" infra COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
check "18g. and estimate.json still cannot escalate infra on claude (7a, restated)" \
  "[ -z \"\$(rsm \"$r18d\" infra CLAUDECODE=1 | sm_model)\" ]"

# === Behavior 19 (S202): the numberOne stage key — the Opus pin =============
# THE ROLE MUST HAVE A KEY. `stage_key_for_role` returns EMPTY for a role it does
# not know, and resolve_stage_model's whole ladder is skipped for an empty key —
# so a Number One worker with no key falls straight through to the legacy
# no-`--model` path and runs on copilot's DEFAULT model. S194 measured what that
# costs: copilot's default `create` tool cannot write the file, so the worker is
# hired, reasons, reports what it "wrote", and the harness finds nothing on disk.
# That is exactly the failure `number-one) numberOne` prevents, so these checks
# drive the KEY, not just the value.
#
# The captain's ruling (2026-09-11): a copilot Number One resolves through the
# S194 write floor like every other copilot worker — write_capable_alias →
# alias_for_tier copilot opus → modelAliases.copilot.opus, default
# claude-opus-4.8. `numberOne.model` in config may override it; LCARS_WORKER_MODEL
# outranks both. Claude is untouched (its floor is empty on purpose).
r19="$(make_repo '{}')"
check "19a. copilot numberOne ⇒ the write floor's opus alias (claude-opus-4.8)" \
  "[ \"\$(rsm \"$r19\" numberOne COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
check "19b. claude numberOne ⇒ NO --model (claude's floor is empty; argv unchanged)" \
  "[ -z \"\$(rsm \"$r19\" numberOne CLAUDECODE=1 | sm_model)\" ]"

# modelAliases.copilot.opus re-points the floor — one home for the mapping.
r19b="$(make_repo '{"modelAliases":{"copilot":{"opus":"claude-opus-9.9"}}}')"
check "19c. modelAliases.copilot.opus re-points the Number One pin" \
  "[ \"\$(rsm \"$r19b\" numberOne COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-9.9' ]"

# config numberOne.model — the captain's own pin for HIS first officer, verbatim
# (it is a raw flag, like workerModel, not a logical tier).
r19c="$(make_repo '{"numberOne": {"enabled": true, "engine": "copilot", "model": "claude-haiku-4.5"}}')"
check "19d. config numberOne.model overrides the floor, verbatim" \
  "[ \"\$(rsm \"$r19c\" numberOne COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-haiku-4.5' ]"
check "19e. …and it touches NO other stage (research still resolves the floor)" \
  "[ \"\$(rsm \"$r19c\" research COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot | sm_model)\" = 'claude-opus-4.8' ]"
check "19f. LCARS_WORKER_MODEL outranks numberOne.model" \
  "[ \"\$(rsm \"$r19c\" numberOne COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_WORKER_MODEL=pinned-by-env | sm_model)\" = 'pinned-by-env' ]"

# The captain's whole-way override reaches Number One; a scoped one does not.
# numberOne is in `all` ONLY: `reasoning` and `implementation` are the ESTIMATOR's
# two axes over the pipeline's own stages, and the first officer is neither.
r19d="$(make_repo '{"modelAliases":{"copilot":{"sonnet":"claude-sonnet-4.6"}}}')"
check "19g. all:sonnet override reaches numberOne" \
  "[ \"\$(rsm \"$r19d\" numberOne COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_MODEL_OVERRIDE=all:sonnet | sm_model)\" = 'claude-sonnet-4.6' ]"
check "19h. reasoning:sonnet does NOT (numberOne is not a reasoning STAGE)" \
  "[ \"\$(rsm \"$r19d\" numberOne COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_MODEL_OVERRIDE=reasoning:sonnet | sm_model)\" = 'claude-opus-4.8' ]"
check "19i. implementation:sonnet does NOT either" \
  "[ \"\$(rsm \"$r19d\" numberOne COPILOT_RUN_APP=1 LCARS_WORKER_CLI=copilot LCARS_MODEL_OVERRIDE=implementation:sonnet | sm_model)\" = 'claude-opus-4.8' ]"

# THE KEY ITSELF, through the REAL spawn chokepoint: worker_spawn maps the env
# ROLE `number-one` → the stage key → the model → the adapter argv. A missing map
# line shows up here as a spawn with NO --model at all, because an empty key
# skips the whole ladder. (spawn_argv pins the cli to claude, so the pin under
# test here is the captain's own `numberOne.model` — which only a real key can
# reach.)
r19e="$(make_repo '{"numberOne": {"enabled": true, "engine": "claude", "model": "pinned-by-config"}}')"
check "19j. spawn-stage number-one reaches the numberOne key end-to-end" \
  "[ \"\$(spawn_argv \"$r19e\" number-one CLAUDECODE=1 | model_of)\" = 'pinned-by-config' ]"
check "19k. …and an UNMAPPED role still resolves nothing (the key is what did it)" \
  "[ -z \"\$(spawn_argv \"$r19e\" plan CLAUDECODE=1 | model_of)\" ]"

echo "stage-model: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
