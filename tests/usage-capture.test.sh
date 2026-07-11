#!/usr/bin/env bash
#
# Tests for USAGE CAPTURE (session 112) — the per-spawn actual-usage side-channel.
#
# worker_spawn (skills/lcars-run/run.sh) mints a fresh --session-id per cold
# worker (when capture is enabled), the adapter pins it, and after the worker
# exits usage_capture() parses the CLI's own on-disk session artifact keyed by
# that id, computes cost from pricing.json, appends ONE record to the mission's
# usage.json, and emits a `worker_usage` event. `run.sh usage --mission <id>`
# sums it.
#
# We drive the REAL worker_spawn chokepoint via the `spawn-stage <role>` test
# subcommand through a recording stub CLI that ALSO writes the redacted real-CLI
# fixture artifact into the (env-overridable) session-artifact location keyed by
# the minted id — so usage_capture parses a real transcript shape.
#
# Usage: bash tests/usage-capture.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/skills/lcars-run/run.sh"
FIX="$REPO_ROOT/tests/fixtures/usage"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# A stub CLI. Records its full argv to $STUB_ARGV. If a session-id is present in
# argv AND $STUB_FIXTURE is set, it copies that fixture into the on-disk session
# artifact location for $STUB_ENGINE, keyed by the minted id (mimicking the real
# CLI writing its transcript/session-state). Absent fixture ⇒ no artifact (the
# `unavailable` degrade path). Prints something on stdout so capture proves.
make_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
: >"${STUB_ARGV:-/dev/null}"
sid=""; prev=""
for a in "$@"; do
  [ -n "${STUB_ARGV:-}" ] && printf '%s\n' "$a" >>"$STUB_ARGV"
  [ "$prev" = "--session-id" ] && sid="$a"
  prev="$a"
done
if [ -n "$sid" ] && [ -n "${STUB_FIXTURE:-}" ]; then
  case "${STUB_ENGINE:-}" in
    claude)  mkdir -p "$LCARS_CLAUDE_PROJECTS_DIR/proj"
             cp "$STUB_FIXTURE" "$LCARS_CLAUDE_PROJECTS_DIR/proj/$sid.jsonl" ;;
    copilot) mkdir -p "$LCARS_COPILOT_SESSION_DIR/$sid"
             cp "$STUB_FIXTURE" "$LCARS_COPILOT_SESSION_DIR/$sid/events.jsonl" ;;
  esac
fi
printf 'STDOUT\n'
exit 0
EOF
  chmod +x "$1"
}

# Fresh throwaway repo with .git/lcars/config.json + a mission M1. $1 = config body.
make_repo() { # config-json
  local d; d="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$d" && git init -q )
  mkdir -p "$d/.git/lcars/missions/M1"
  printf '%s\n' "${1:-{\}}" >"$d/.git/lcars/config.json"
  printf '{ "id": "M1" }\n' >"$d/.git/lcars/missions/M1/state.json"
  printf '%s' "$d"
}

# Drive one spawn-stage through the stub, with capture on/off + engine + fixture.
#   drive <repo> <role> <cli> <capture 0|1> <fixture-or-empty> [extra env...]
drive() {
  local repo="$1" role="$2" cli="$3" cap="$4" fix="$5"; shift 5
  local stub="$repo/stub-$cli"; make_stub "$stub"
  ( cd "$repo" && env -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      STUB_ARGV="$repo/stub.argv" \
      STUB_ENGINE="$cli" ${fix:+STUB_FIXTURE="$fix"} \
      LCARS_CLAUDE_PROJECTS_DIR="$repo/.claude/projects" \
      LCARS_COPILOT_SESSION_DIR="$repo/.copilot/session-state" \
      LCARS_USAGE_CAPTURE="$cap" \
      LCARS_WORKER_BIN="$stub" LCARS_WORKER_CLI="$cli" \
      "$@" \
      bash "$RUN" spawn-stage --mission M1 "$role" >/dev/null 2>&1 )
}

usage_file() { printf '%s' "$1/.git/lcars/missions/M1/usage.json"; }
events_file(){ printf '%s' "$1/.git/lcars/missions/M1/events.jsonl"; }
# Read a numeric/string JSON field from the LAST usage.json record.
last_field() { # repo key
  tail -1 "$(usage_file "$1")" 2>/dev/null | "${LCARS_PYTHON_BIN:-python3}" -c \
    "import json,sys; d=json.loads(sys.stdin.read()); v=d.get('$2'); sys.stdout.write('' if v is None else str(v))"
}
rec_count() { wc -l <"$(usage_file "$1")" 2>/dev/null | tr -d ' '; }

echo "usage-capture — per-spawn actual usage side-channel (session 112)"

# === 1. claude: fixture artifact → correct usage.json record ==================
r1="$(make_repo '{}')"
drive "$r1" research-questions claude 1 "$FIX/claude-transcript.jsonl"
check "1a. exactly one usage record appended"       "[ \"\$(rec_count \"$r1\")\" = '1' ]"
check "1b. stage = research"                          "[ \"\$(last_field \"$r1\" stage)\" = 'research' ]"
check "1c. role = research-questions"                 "[ \"\$(last_field \"$r1\" role)\" = 'research-questions' ]"
check "1d. engine = claude"                           "[ \"\$(last_field \"$r1\" engine)\" = 'claude' ]"
check "1e. model = claude-opus-4-8"                   "[ \"\$(last_field \"$r1\" model)\" = 'claude-opus-4-8' ]"
check "1f. inputTokens = 2"                           "[ \"\$(last_field \"$r1\" inputTokens)\" = '2' ]"
check "1g. outputTokens = 3"                          "[ \"\$(last_field \"$r1\" outputTokens)\" = '3' ]"
check "1h. cacheReadTokens = 16907"                   "[ \"\$(last_field \"$r1\" cacheReadTokens)\" = '16907' ]"
check "1i. cacheWriteTokens = 8842"                   "[ \"\$(last_field \"$r1\" cacheWriteTokens)\" = '8842' ]"
check "1j. source = session-transcript"               "[ \"\$(last_field \"$r1\" source)\" = 'session-transcript' ]"
check "1k. billingUnit = usd"                         "[ \"\$(last_field \"$r1\" billingUnit)\" = 'usd' ]"
# The minted --session-id reached the spawned argv (byte delta present when ON).
check "1l. spawned argv carries --session-id"         "[ -n \"\$(grep -x -- --session-id \"$r1/stub.argv\")\" ]"

# === 2. cost math matches a pricing.json hand-calc (claude opus) ==============
# (2*5 + 3*25 + 16907*5*0.1 + 8842*5*1.25)/1e6 = 63801/1e6 = 0.063801
check "2a. costUsd = 0.063801 (hand-calc)"            "[ \"\$(last_field \"$r1\" costUsd)\" = '0.063801' ]"
check "2b. cost mirrors costUsd for usd unit"         "[ \"\$(last_field \"$r1\" cost)\" = '0.063801' ]"

# === 3. events.jsonl carries a worker_usage event =============================
check "3a. worker_usage event emitted" \
  "grep -q '\"type\":\"worker_usage\"' \"$(events_file "$r1")\""
check "3b. event carries inputTokens=2" \
  "grep '\"type\":\"worker_usage\"' \"$(events_file "$r1")\" | grep -q '\"inputTokens\":2'"

# === 4. copilot (usage billing): fixture → record + cost ======================
r4="$(make_repo '{}')"   # default copilot billing = usage
drive "$r4" validate copilot 1 "$FIX/copilot-events.jsonl"
check "4a. one record"                                "[ \"\$(rec_count \"$r4\")\" = '1' ]"
check "4b. engine = copilot"                          "[ \"\$(last_field \"$r4\" engine)\" = 'copilot' ]"
check "4c. stage = validate"                          "[ \"\$(last_field \"$r4\" stage)\" = 'validate' ]"
check "4d. model = claude-opus-4.8"                   "[ \"\$(last_field \"$r4\" model)\" = 'claude-opus-4.8' ]"
check "4e. inputTokens = 73093"                       "[ \"\$(last_field \"$r4\" inputTokens)\" = '73093' ]"
check "4f. outputTokens = 3"                          "[ \"\$(last_field \"$r4\" outputTokens)\" = '3' ]"
check "4g. premiumRequests = 15 recorded"             "[ \"\$(last_field \"$r4\" premiumRequests)\" = '15' ]"
check "4h. source = session-state"                    "[ \"\$(last_field \"$r4\" source)\" = 'session-state' ]"
check "4i. billingUnit = usd (usage billing)"         "[ \"\$(last_field \"$r4\" billingUnit)\" = 'usd' ]"
# (73093*5 + 3*25)/1e6 = 365540/1e6 = 0.36554
check "4j. costUsd = 0.36554 (copilot.usage hand-calc)" "[ \"\$(last_field \"$r4\" costUsd)\" = '0.36554' ]"

# === 5. copilot LEGACY billing: unit = premiumRequests, cost = requests =======
r5="$(make_repo '{ "copilotBilling": "legacy" }')"
drive "$r5" plan copilot 1 "$FIX/copilot-events.jsonl"
check "5a. billingUnit = premiumRequests"             "[ \"\$(last_field \"$r5\" billingUnit)\" = 'premiumRequests' ]"
check "5b. cost = 15 (premium requests)"              "[ \"\$(last_field \"$r5\" cost)\" = '15' ]"
# 15 * 0.04 overage = 0.6
check "5c. costUsd = 0.6 (overage hand-calc)"         "[ \"\$(last_field \"$r5\" costUsd)\" = '0.6' ]"

# === 6. DEGRADE: mechanism finds nothing → unavailable, stage still succeeds ===
r6="$(make_repo '{}')"
# No fixture ⇒ stub writes no artifact ⇒ capture finds nothing.
drive "$r6" validate claude 1 ""
_rc6=$?
check "6a. spawn-stage still exited 0 (never a stage failure)" "[ \"$_rc6\" = '0' ]"
check "6b. one unavailable record"                    "[ \"\$(rec_count \"$r6\")\" = '1' ]"
check "6c. source = unavailable"                      "[ \"\$(last_field \"$r6\" source)\" = 'unavailable' ]"
check "6d. unavailable event has data.unavailable=1" \
  "grep '\"type\":\"worker_usage\"' \"$(events_file "$r6")\" | grep -q '\"unavailable\":1'"

# === 7. CAPTURE OFF: no --session-id in argv, no usage.json (sacred path) ======
r7="$(make_repo '{}')"
drive "$r7" plan claude 0 "$FIX/claude-transcript.jsonl"
check "7a. NO --session-id in spawned argv when OFF" \
  "[ -z \"\$(grep -x -- --session-id \"$r7/stub.argv\")\" ]"
check "7b. no usage.json written when OFF"            "[ ! -f \"\$(usage_file \"$r7\")\" ]"

# === 8. ALL-STAGES coverage: each spawn appends EXACTLY ONE record =============
r8="$(make_repo '{}')"
for role in research-questions validate plan plan-review implement-implementer; do
  drive "$r8" "$role" claude 1 "$FIX/claude-transcript.jsonl"
done
check "8a. five spawns → five records (one per spawn)" "[ \"\$(rec_count \"$r8\")\" = '5' ]"
# The five distinct stage keys are all present.
for st in research validate plan planReview implement; do
  check "8b.$st stage recorded once" \
    "[ \"\$(grep -c '\"stage\":\"$st\"' \"$(usage_file "$r8")\")\" = '1' ]"
done

# === 9. run.sh usage <mission> sums usage.json per stage + total ===============
# Reuse r8 (five claude records, each inputTokens=2, outputTokens=3, cost 0.063801).
u_out="$( cd "$r8" && bash "$RUN" usage --mission M1 2>/dev/null )"
check "9a. usage header names the mission" \
  "printf '%s' \"\$u_out\" | grep -q '^USAGE mission=M1'"
check "9b. TOTAL records=5" \
  "printf '%s' \"\$u_out\" | grep -Eq '^TOTAL records=5 '"
check "9c. TOTAL inputTokens=10 (5*2)" \
  "printf '%s' \"\$u_out\" | grep -q 'inputTokens=10'"
check "9d. TOTAL outputTokens=15 (5*3)" \
  "printf '%s' \"\$u_out\" | grep -q 'outputTokens=15'"
check "9e. per-stage research line present" \
  "printf '%s' \"\$u_out\" | grep -q '^STAGE research records=1'"
# Grand total cost = 5 * 0.063801 = 0.319005
check "9f. TOTAL costUsd=0.319005" \
  "printf '%s' \"\$u_out\" | grep -q 'costUsd=0.319005'"
check "9g. usage on a mission with no usage.json → records=0" \
  "( cd \"$(make_repo '{}')\" && bash \"$RUN\" usage --mission M1 2>/dev/null | grep -q '^TOTAL records=0' )"

echo
printf 'usage-capture: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
