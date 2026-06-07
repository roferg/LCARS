#!/usr/bin/env bash
#
# Tests for the cold-worker CLI adapter (skills/lcars-run/worker-adapter.sh).
#
# The adapter is the ONE place that knows CLI-specific flags and tool NAMES.
# run.sh now speaks only role keywords + a cli id (basename of the worker bin).
# These unit tests are the regression lock on the Claude flags/tool-lists that
# run.sh used to hardcode in worker_tools() + the inline `-p … --allowedTools …`.
#
#   argv  <cli> <role> <outdir>  → flags, one per line (no prompt). Pure.
#   spawn <cli> <role> <outdir> <prompt> → run the cli one-shot, capture out/err.
#
# We stub `claude` with a recording binary (the LCARS_GH_BIN pattern) so spawn's
# argv + env are asserted without running anything real.
#
# Usage: bash tests/worker-adapter.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="${LCARS_WORKER_ADAPTER:-$REPO_ROOT/skills/lcars-run/worker-adapter.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# A fake `claude` that records its full argv (one arg per line) to $CLAUDE_ARGV
# and its role/out env to $CLAUDE_ENV, then echoes something on stdout+stderr so
# we can prove capture. Records nothing about the prompt body beyond its presence.
make_claude_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
: >"$CLAUDE_ARGV"
for a in "$@"; do printf '%s\n' "$a" >>"$CLAUDE_ARGV"; done
printf 'role=%s out=%s\n' "${LCARS_WORKER_ROLE:-}" "${LCARS_WORK_OUT:-}" >"$CLAUDE_ENV"
printf 'STDOUT-MARKER\n'
printf 'STDERR-MARKER\n' >&2
exit 0
EOF
  chmod +x "$1"
}

echo "worker-adapter — the one CLI-specific seam (session 18)"

# --- 1. argv claude repo-read emits the exact 5 lines, order-sensitive --------
d1="$(mktemp -d "$TMPROOT/d.XXXX")"
A1="$(bash "$ADAPTER" argv claude repo-read "$d1")"
EXPECT_1='-p
--allowedTools
Read,Grep,Glob,Write
--output-format
text'
check "1. argv claude repo-read → exact 5 lines in order" \
  "[ \"\$A1\" = \"\$EXPECT_1\" ]"

# --- 2. each role yields TODAY's Claude tool list (regression lock) ------------
tool_line() { bash "$ADAPTER" argv claude "$1" "$TMPROOT" | sed -n '3p'; }
check "2a. repo-read     → Read,Grep,Glob,Write" \
  "[ \"\$(tool_line repo-read)\" = 'Read,Grep,Glob,Write' ]"
check "2b. repo-read-web → +WebSearch,WebFetch" \
  "[ \"\$(tool_line repo-read-web)\" = 'Read,Grep,Glob,Write,WebSearch,WebFetch' ]"
check "2c. repo-write    → +Edit,Bash" \
  "[ \"\$(tool_line repo-write)\" = 'Read,Grep,Glob,Write,Edit,Bash' ]"
check "2d. default       → Read (the old \`*\` case)" \
  "[ \"\$(tool_line default)\" = 'Read' ]"

# argv never emits the prompt — purely flags.
check "2e. argv emits exactly 5 lines (no prompt)" \
  "[ \"\$(bash \"$ADAPTER\" argv claude repo-read \"$d1\" | wc -l | tr -d ' ')\" = '5' ]"

# --- 3. spawn runs the (stubbed) claude with -p <prompt> + flags, captures -----
d3="$(mktemp -d "$TMPROOT/d.XXXX")"
make_claude_stub "$d3/claude"
export CLAUDE_ARGV="$d3/argv.log" CLAUDE_ENV="$d3/env.log"
LCARS_WORKER_BIN="$d3/claude" bash "$ADAPTER" spawn claude repo-read "$d3/out" "THE PROMPT BODY"
# Byte-for-byte the old call: -p <prompt> --allowedTools <list> --output-format text
EXPECT_ARGV='-p
THE PROMPT BODY
--allowedTools
Read,Grep,Glob,Write
--output-format
text'
check "3a. spawn argv = -p <prompt> --allowedTools <list> --output-format text" \
  "[ \"\$(cat \"$d3/argv.log\")\" = \"\$EXPECT_ARGV\" ]"
check "3b. spawn sets LCARS_WORKER_ROLE + LCARS_WORK_OUT" \
  "grep -q 'role=repo-read out=$d3/out' \"$d3/env.log\""
check "3c. spawn captures stdout → <outdir>/.worker.out" \
  "grep -q STDOUT-MARKER \"$d3/out/.worker.out\""
check "3d. spawn captures stderr → <outdir>/.worker.err" \
  "grep -q STDERR-MARKER \"$d3/out/.worker.err\""

# --- 3e. spawn never fails the caller, even when the cli exits non-zero --------
d3e="$(mktemp -d "$TMPROOT/d.XXXX")"
cat >"$d3e/claude" <<'EOF'
#!/usr/bin/env bash
exit 17
EOF
chmod +x "$d3e/claude"
LCARS_WORKER_BIN="$d3e/claude" bash "$ADAPTER" spawn claude repo-read "$d3e/out" "p"; rc=$?
check "3e. spawn returns 0 even when the worker exits non-zero (|| true)" \
  "[ \"$rc\" = '0' ]"

# --- 4. unknown cli AND unknown role each exit non-zero -----------------------
bash "$ADAPTER" argv copilot repo-read "$TMPROOT" >/dev/null 2>"$TMPROOT/e1"; rc_cli=$?
check "4a. unknown cli → argv exits non-zero" "[ \"$rc_cli\" != '0' ]"
check "4b. unknown cli → message on stderr" "[ -s \"$TMPROOT/e1\" ]"

bash "$ADAPTER" argv claude bogus-role "$TMPROOT" >/dev/null 2>"$TMPROOT/e2"; rc_role=$?
check "4c. unknown role → argv exits non-zero (no silent empty argv)" "[ \"$rc_role\" != '0' ]"
check "4d. unknown role → message on stderr" "[ -s \"$TMPROOT/e2\" ]"

# spawn must also refuse an unknown cli/role rather than run something blank.
d4="$(mktemp -d "$TMPROOT/d.XXXX")"; make_claude_stub "$d4/claude"
export CLAUDE_ARGV="$d4/argv.log" CLAUDE_ENV="$d4/env.log"; : >"$d4/argv.log"
LCARS_WORKER_BIN="$d4/claude" bash "$ADAPTER" spawn claude bogus-role "$d4/out" "p" \
  >/dev/null 2>"$TMPROOT/e3"; rc_sp=$?
check "4e. spawn unknown role → non-zero, never runs the cli" \
  "[ \"$rc_sp\" != '0' ] && [ ! -s \"$d4/argv.log\" ]"

# --- 5. context-pack role/toolset SPLIT: caller-set LCARS_WORKER_ROLE wins -----
# generate_context_pack() uses the repo-read TOOLSET but the worker must still see
# LCARS_WORKER_ROLE=context-pack. So spawn takes repo-read for argv, yet does NOT
# overwrite a pre-exported LCARS_WORKER_ROLE.
d5="$(mktemp -d "$TMPROOT/d.XXXX")"; make_claude_stub "$d5/claude"
export CLAUDE_ARGV="$d5/argv.log" CLAUDE_ENV="$d5/env.log"
LCARS_WORKER_BIN="$d5/claude" LCARS_WORKER_ROLE="context-pack" \
  bash "$ADAPTER" spawn claude repo-read "$d5/out" "p"
check "5a. context-pack: caller's LCARS_WORKER_ROLE=context-pack is preserved" \
  "grep -q 'role=context-pack out=$d5/out' \"$d5/env.log\""
check "5b. context-pack: argv still uses the repo-read toolset" \
  "grep -q '^Read,Grep,Glob,Write\$' \"$d5/argv.log\""

echo "worker-adapter: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
