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
# (copilot is now a KNOWN cli — use a genuinely-unknown id for the lock.)
bash "$ADAPTER" argv gemini repo-read "$TMPROOT" >/dev/null 2>"$TMPROOT/e1"; rc_cli=$?
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

# ============================================================================
# COPILOT adapter (session 20) — second CLI behind the same role keywords.
# The ONLY copilot-specific code lives in worker-adapter.sh; these tests pin the
# tool fences + the byte-for-byte argv order for the copilot path.
# ============================================================================
echo "worker-adapter — copilot adapter (session 20)"

# A fake `copilot` recording its argv/env exactly like the claude stub.
make_copilot_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
: >"$COPILOT_ARGV"
for a in "$@"; do printf '%s\n' "$a" >>"$COPILOT_ARGV"; done
printf 'role=%s out=%s\n' "${LCARS_WORKER_ROLE:-}" "${LCARS_WORK_OUT:-}" >"$COPILOT_ENV"
printf 'STDOUT-MARKER\n'
printf 'STDERR-MARKER\n' >&2
exit 0
EOF
  chmod +x "$1"
}

# The copilot tool list is the token after `--available-tools` (a single
# comma-list, mirroring claude's `--allowedTools <list>`). Pull it generically:
# print the line FOLLOWING the `--available-tools` flag.
cop_tools() { # role
  bash "$ADAPTER" argv copilot "$1" "$TMPROOT" \
    | awk '/^--available-tools$/{getline; print; exit}'
}

# --- C1. repo-read fences to view,grep,glob,create (no bash/web) ---------------
check "C1a. copilot repo-read → view,grep,glob,create" \
  "[ \"\$(cop_tools repo-read)\" = 'view,grep,glob,create' ]"
check "C1b. copilot repo-read has NO bash in the tool list" \
  "[ -z \"\$(cop_tools repo-read | grep -o bash)\" ]"
check "C1c. copilot repo-read has NO web_fetch/web_search in the tool list" \
  "[ -z \"\$(cop_tools repo-read | grep -oE 'web_fetch|web_search')\" ]"

# --- C2. per-role tool fences -------------------------------------------------
check "C2a. copilot repo-read-web → +web_fetch,web_search" \
  "[ \"\$(cop_tools repo-read-web)\" = 'view,grep,glob,create,web_fetch,web_search' ]"
check "C2b. copilot repo-write → +edit,bash" \
  "[ \"\$(cop_tools repo-write)\" = 'view,grep,glob,create,edit,bash' ]"
check "C2c. copilot default → view" \
  "[ \"\$(cop_tools default)\" = 'view' ]"

# --- C3. EVERY copilot role carries the cold-worker hardening flags ------------
has_flag() { # role flag
  # Capture argv first, then match — piping a producer into `grep -q` can
  # SIGPIPE the producer and trip `set -o pipefail` (a false negative), so we
  # grep over a captured string with no upstream process to kill.
  local argv
  argv="$(bash "$ADAPTER" argv copilot "$1" "$TMPROOT")"
  grep -qxF -e "$2" <<<"$argv"
}
for r in repo-read repo-read-web repo-write default; do
  for f in --no-ask-user --disable-builtin-mcps --no-custom-instructions \
           --allow-all-tools -s; do
    check "C3. copilot $r argv carries $f" "has_flag $r '$f'"
  done
  # --add-dir <outdir> — assert the literal dir passed appears right after.
  cd3="$(mktemp -d "$TMPROOT/d.XXXX")"
  check "C3. copilot $r argv carries --add-dir <outdir> (literal)" \
    "[ \"\$(bash \"$ADAPTER\" argv copilot $r \"$cd3\" | awk '/^--add-dir\$/{getline; print; exit}')\" = \"$cd3\" ]"
done

# --- C4. --model present IFF LCARS_WORKER_MODEL set ----------------------------
# unset → no --model line for copilot.
check "C4a. copilot argv has NO --model when LCARS_WORKER_MODEL unset" \
  "[ -z \"\$(LCARS_WORKER_MODEL= bash \"$ADAPTER\" argv copilot repo-read \"$TMPROOT\" | grep -x -- --model)\" ]"
# set → --model + the value appear, value right after the flag.
check "C4b. copilot argv has --model some-model when LCARS_WORKER_MODEL=some-model" \
  "[ \"\$(LCARS_WORKER_MODEL=some-model bash \"$ADAPTER\" argv copilot repo-read \"$TMPROOT\" | awk '/^--model\$/{getline; print; exit}')\" = 'some-model' ]"
# Regression lock: claude argv STILL byte-for-byte the session-18 lines (no model).
A4c="$(LCARS_WORKER_MODEL= bash "$ADAPTER" argv claude repo-read "$d1")"
check "C4c. claude argv unchanged (session-18 lock) when model unset" \
  "[ \"\$A4c\" = \"\$EXPECT_1\" ]"

# --- C5. order-sensitive byte-for-byte lock for copilot repo-read --------------
A5="$(LCARS_WORKER_MODEL= bash "$ADAPTER" argv copilot repo-read "$d1")"
EXPECT_5="-p
-s
--available-tools
view,grep,glob,create
--allow-all-tools
--no-ask-user
--disable-builtin-mcps
--no-custom-instructions
--add-dir
$d1"
check "C5. argv copilot repo-read → exact lines in order (byte-for-byte lock)" \
  "[ \"\$A5\" = \"\$EXPECT_5\" ]"

# --- C6. unknown role under copilot exits non-zero ----------------------------
bash "$ADAPTER" argv copilot bogus-role "$TMPROOT" >/dev/null 2>"$TMPROOT/ec6"; rc_c6=$?
check "C6a. copilot unknown role → argv exits non-zero" "[ \"$rc_c6\" != '0' ]"
check "C6b. copilot unknown role → message on stderr" "[ -s \"$TMPROOT/ec6\" ]"

# --- C7. spawn copilot runs the stub with -p <prompt> + role flags, captures ---
dc7="$(mktemp -d "$TMPROOT/d.XXXX")"
make_copilot_stub "$dc7/copilot"
export COPILOT_ARGV="$dc7/argv.log" COPILOT_ENV="$dc7/env.log"
LCARS_WORKER_MODEL= LCARS_WORKER_BIN="$dc7/copilot" \
  bash "$ADAPTER" spawn copilot repo-read "$dc7/out" "THE PROMPT BODY"
EXPECT_C7='-p
THE PROMPT BODY
-s
--available-tools
view,grep,glob,create
--allow-all-tools
--no-ask-user
--disable-builtin-mcps
--no-custom-instructions
--add-dir
'"$dc7/out"
check "C7a. spawn copilot argv = -p <prompt> then the role flags (order-locked)" \
  "[ \"\$(cat \"$dc7/argv.log\")\" = \"\$EXPECT_C7\" ]"
check "C7b. spawn copilot sets LCARS_WORKER_ROLE + LCARS_WORK_OUT" \
  "grep -q 'role=repo-read out=$dc7/out' \"$dc7/env.log\""
check "C7c. spawn copilot captures stdout → <outdir>/.worker.out" \
  "grep -q STDOUT-MARKER \"$dc7/out/.worker.out\""
check "C7d. spawn copilot captures stderr → <outdir>/.worker.err" \
  "grep -q STDERR-MARKER \"$dc7/out/.worker.err\""

echo "worker-adapter: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
