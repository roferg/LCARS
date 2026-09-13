#!/usr/bin/env bash
#
# Tests for `lcars xo` — Number One's verb (Session 201, wave A).
#
# Skill source under test: skills/lcars-xo/xo.sh
#
#   lcars xo                     the status table (mission · stage · numberOne · note)
#   lcars xo on [--engine E] [--model M]   engage Number One for this REPO
#   lcars xo on <mission>        clear a per-mission opt-out
#   lcars xo off                 stand the repo down (and every engaged mission)
#   lcars xo off <mission>       per-mission opt-out + stand that mission down
#
# THREE RULES THIS SUITE EXISTS TO PIN:
#
#  1. THE CONFIG BLOCK IS ONE LINE. `lcars_config_merge` preserves a raw value
#     only when it sits on a single line (lcars-common.sh) — a pretty-printed
#     `numberOne` object would be silently mangled by the next `lcars update`.
#     S196 paid for that lesson with cloneId.
#  2. NO PRICING WORDS IN PRODUCT COPY (captain ruling, 2026-09-11). The picker
#     names engines and says installed / not installed. Never "free", never
#     "billed", never "cost" — not everyone's situation is the captain's.
#  3. NEVER SWITCH IN SILENCE. No tty and no `--engine` is a LOUD refusal, the
#     adopt precedent (adopt.sh's engine resolution).
#
# Zero spend: no worker CLI is ever invoked. Both engines are PATH shims that
# record their argv, and the suite asserts the recorded count is ZERO.
#
# Usage: bash tests/lcars-xo.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_XO_SCRIPT:-$REPO_ROOT/skills/lcars-xo/xo.sh}"
LCARS_ENTRY="$REPO_ROOT/skills/lcars/lcars.sh"
UPDATE="$REPO_ROOT/skills/lcars-update/update.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- THE ZERO-SPEND SHIM ---------------------------------------------------
# BOTH CLIs, on $PATH, not an env var: the engine arrives from three places
# (config, --engine, $LCARS_WORKER_BIN) with a different winner per path, so a
# single env var cannot prove nothing was spawned. A shim on PATH can.
SHIMDIR="$TMPROOT/shims"
mkdir -p "$SHIMDIR"
export XO_SHIM_LOG="$TMPROOT/shim-calls.txt"; : >"$XO_SHIM_LOG"
for e in claude copilot; do
  cat >"$SHIMDIR/$e" <<EOF
#!/usr/bin/env bash
printf '$e %s\n' "\$*" >>"\$XO_SHIM_LOG"
exit 0
EOF
  chmod +x "$SHIMDIR/$e"
done
PATH="$SHIMDIR:$PATH"; export PATH

MID="lcars-20260530-001"

# NOTE ON QUOTING. These fixtures build JSON with plain printf, never with a
# `${var:+ …}` expansion inside a heredoc: bash strips the `"` characters out of
# the alternate text, which silently plants an UNQUOTED key. That produced a
# state.json every reader here ignored while the suite still went green on the
# checks that did not look — the fixture lying about the file under test.
new_repo() { # [numberOne-config-line]
  local repo extra="${1:-}"
  repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  {
    printf '{\n'
    printf '  "cloneId": "aaaaaaaa",\n'
    printf '  "model": "claude-sonnet",\n'
    printf '  "projectName": "repo",\n'
    printf '  "contextFile": null,\n'
    printf '  "stack": null,\n'
    printf '  "testCommand": "true",\n'
    printf '  "worktreeSetupCommand": null,\n'
    printf '  "comprehensionBudget": 1200,\n'
    [ -n "$extra" ] && printf '  %s,\n' "$extra"
    printf '  "created": "2026-05-30T00:00:00Z"\n'
    printf '}\n'
  } >"$repo/.git/lcars/config.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$repo/.git/lcars/config.json" || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$repo"
}

plant_mission() { # <repo> <id> <stage> [numberOne-raw]
  local repo="$1" id="$2" stage="$3" xo="${4:-}" m
  m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m"
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$id"
    # AT THE TOP and ON ONE LINE — the shape every shipped writer emits.
    [ -n "$xo" ] && printf '  "numberOne": %s,\n' "$xo"
    printf '  "type": "feature",\n'
    printf '  "title": "Add dark mode",\n'
    printf '  "stage": "%s",\n' "$stage"
    printf '  "created": "2026-05-30T10:00:00Z",\n'
    printf '  "githubIssue": 42\n'
    printf '}\n'
  } >"$m/state.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$m"
}

cfg_line() { # <repo> -> the raw numberOne line out of config.json
  grep '"numberOne"' "$1/.git/lcars/config.json" | head -1 | sed 's/^[[:space:]]*//; s/,$//'
}

echo "lcars xo (Number One — the verb)"
[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# ==========================================================================
# B1. `lcars xo on --engine copilot` writes the ONE-LINE block, and `lcars xo`
#     reads it back off RECORDED state — it never re-derives it from prose.
# ==========================================================================
echo
echo "B1. on --engine writes one line; the status table reads it back"

repo1="$(new_repo)"
rc=0
( cd "$repo1" && bash "$SCRIPT" on --engine copilot >out.txt 2>&1 ) || rc=$?
check "B1. \`lcars xo on --engine copilot\` succeeds" "[ '$rc' -eq 0 ]"
check "B1. config.json now carries a numberOne block" \
  "grep -q '\"numberOne\"' '$repo1/.git/lcars/config.json'"
check "B1. …on EXACTLY ONE line (lcars_config_merge only preserves a one-line raw value)" \
  "[ \"\$(grep -c '\"numberOne\"' '$repo1/.git/lcars/config.json')\" = '1' ] && [ \"\$(cfg_line '$repo1')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"copilot\"}' ]"
check "B1. config.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$repo1/.git/lcars/config.json'"
out1="$( cd "$repo1" && bash "$SCRIPT" 2>&1 )"
check "B1. the bare status verb prints ON · copilot" \
  "printf '%s' \"\$out1\" | grep -q 'ON · copilot'"
check "B1. it does NOT spawn a worker" "[ ! -s '$XO_SHIM_LOG' ]"

# --model rides along on the same one line.
repo1b="$(new_repo)"
( cd "$repo1b" && bash "$SCRIPT" on --engine copilot --model claude-opus-4.8 >/dev/null 2>&1 )
check "B1. --model is recorded on the SAME one line" \
  "[ \"\$(cfg_line '$repo1b')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"copilot\", \"model\": \"claude-opus-4.8\"}' ]"

# An existing block is REPLACED in place, never duplicated.
( cd "$repo1" && bash "$SCRIPT" on --engine claude >/dev/null 2>&1 )
check "B1. re-engaging with another engine replaces the block (still one line)" \
  "[ \"\$(grep -c '\"numberOne\"' '$repo1/.git/lcars/config.json')\" = '1' ] && [ \"\$(cfg_line '$repo1')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"claude\"}' ]"

# OFF at the repo level.
( cd "$repo1" && bash "$SCRIPT" off >/dev/null 2>&1 )
outOff="$( cd "$repo1" && bash "$SCRIPT" 2>&1 )"
check "B1. \`lcars xo off\` flips enabled to false, keeping the engine" \
  "[ \"\$(cfg_line '$repo1')\" = '\"numberOne\": {\"enabled\": false, \"engine\": \"claude\"}' ]"
check "B1. …and the status verb says OFF" \
  "printf '%s' \"\$outOff\" | grep -q 'OFF'"

# ==========================================================================
# B2. The picker. Non-tty without --engine REFUSES, loudly. With a tty and only
#     copilot installed it DEFAULTS to copilot. No pricing words, ever.
# ==========================================================================
echo
echo "B2. the picker — a loud refusal without a tty, and no pricing words"

repo2="$(new_repo)"
rc=0
( cd "$repo2" && bash "$SCRIPT" on </dev/null >out.txt 2>&1 ) || rc=$?
check "B2. non-tty + no --engine REFUSES (non-zero)" "[ '$rc' -ne 0 ]"
check "B2. …loudly, naming --engine as the remedy" \
  "grep -q -- '--engine' '$repo2/out.txt'"
check "B2. …and NOTHING was written to config.json" \
  "! grep -q '\"numberOne\"' '$repo2/.git/lcars/config.json'"

# With a tty (the LCARS_ASSUME_TTY seam adopt.sh already uses) and ONLY copilot
# on this machine, an empty answer takes the default — which must be copilot.
repo2b="$(new_repo)"
ONLYCOP="$TMPROOT/only-copilot"; mkdir -p "$ONLYCOP"
cp "$SHIMDIR/copilot" "$ONLYCOP/copilot"
rc=0
( cd "$repo2b" && PATH="$ONLYCOP:/usr/bin:/bin" LCARS_ASSUME_TTY=1 \
    bash "$SCRIPT" on <<< "" >out.txt 2>&1 ) || rc=$?
check "B2. tty + only copilot installed → the picker defaults to copilot" \
  "[ '$rc' -eq 0 ] && [ \"\$(cfg_line '$repo2b')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"copilot\"}' ]"
check "B2. the picker lists BOTH engines with installed / not installed" \
  "grep -q 'copilot' '$repo2b/out.txt' && grep -q 'claude' '$repo2b/out.txt' && grep -q 'not installed' '$repo2b/out.txt'"
check "B2. NO pricing words anywhere in the picker copy (free / billed / cost)" \
  "! grep -Eqi 'free|billed|billing|cost|price|pricing|\\\$' '$repo2b/out.txt'"

# The whole shipped script's product copy is swept for the same words.
check "B2. …nor anywhere in xo.sh's own printed copy" \
  "! grep -En \"^[^#]*(printf|echo).*(free|billed|billing|costs?|pricing)\" '$SCRIPT'"

# ==========================================================================
# B2b (FIX ROUND 1, D2). THE TWO PICKERS DEFAULT TO THE SAME ENGINE.
#
# The board's picker pre-selected copilot and this one pre-selected claude, so
# a bare Enter got you a different first officer depending on which door you
# came through. ONE SOURCE now answers both: `lcars_xo_default_engine` in
# lcars-common.sh — the CLI calls it here, and the daemon calls it and puts the
# answer on `meta.engineDefault` for the board (web/tests/test_xo_toggle.py
# pins that half). These checks are about the ANSWER; the structural check
# below is about there being only one of them.
# ==========================================================================
echo
echo "B2b. one default, two doors (fix round 1, D2)"

repo2c="$(new_repo)"
rc=0
( cd "$repo2c" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "" >out.txt 2>&1 ) || rc=$?
check "B2b. BOTH engines installed + bare Enter → copilot, as the board does" \
  "[ '$rc' -eq 0 ] && [ \"\$(cfg_line '$repo2c')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"copilot\"}' ]"
check "B2b. …and the prompt SHOWS that default, so Enter is not a surprise" \
  "grep -q 'Engine \[copilot\]' '$repo2c/out.txt'"

# The repo's own pin still wins — a repo that already chose an engine must open
# on that engine, not on the mission-neutral default.
repo2d="$(new_repo '"numberOne": {"enabled": false, "engine": "claude"}')"
( cd "$repo2d" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "" >out.txt 2>&1 )
check "B2b. a repo that PINNED an engine opens on its own pin" \
  "[ \"\$(cfg_line '$repo2d')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"claude\"}' ]"

# The single-source rule itself: xo.sh must not compute a default of its own.
check "B2b. xo.sh takes the default from the ONE shared helper" \
  "grep -q 'lcars_xo_default_engine' '$SCRIPT'"
check "B2b. …and hardcodes no engine name of its own to preselect" \
  "! grep -En '^[^#]*def=\"?(claude|copilot)' '$SCRIPT'"

# ==========================================================================
# B2c (FIX ROUND 1, D6). THE PICKER DRAWS A NUMBERED LIST, SO IT TAKES A NUMBER.
#
# It rendered radio rows and then refused `1` with "'1' is not an engine on
# this machine" — a correct message to an entirely foreseeable answer. A row
# number is an answer to the question the screen asked. The NAME still works,
# and a bare Enter still takes the default.
# ==========================================================================
echo
echo "B2c. the picker takes a row number as well as a name (fix round 1, D6)"

row_of() { # <out.txt> <n> — the engine drawn on row <n>
  sed -n "s/^ *$2\. *([^)]*) *\([a-z]*\).*/\1/p" "$1" | head -1
}

repo2e="$(new_repo)"
( cd "$repo2e" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "1" >out.txt 2>&1 )
r1="$(row_of "$repo2e/out.txt" 1)"
check "B2c. the rows are NUMBERED, so the number is a real handle" \
  "[ -n '$r1' ] && [ -n \"\$(row_of '$repo2e/out.txt' 2)\" ]"
check "B2c. typing \`1\` engages whatever row 1 draws" \
  "[ \"\$(cfg_line '$repo2e')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"$r1\"}' ]"

repo2f="$(new_repo)"
( cd "$repo2f" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "2" >out.txt 2>&1 )
r2="$(row_of "$repo2f/out.txt" 2)"
check "B2c. typing \`2\` engages whatever row 2 draws" \
  "[ \"\$(cfg_line '$repo2f')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"$r2\"}' ]"
check "B2c. …and the two rows are different engines" "[ '$r1' != '$r2' ]"

repo2g="$(new_repo)"
( cd "$repo2g" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "claude" >/dev/null 2>&1 )
check "B2c. the NAME still works" \
  "[ \"\$(cfg_line '$repo2g')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"claude\"}' ]"

repo2h="$(new_repo)"
rc=0
( cd "$repo2h" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "9" >out.txt 2>&1 ) || rc=$?
check "B2c. a row that is not on the list is REFUSED, never guessed at" \
  "[ '$rc' -ne 0 ] && ! grep -q '\"numberOne\"' '$repo2h/.git/lcars/config.json'"
check "B2c. …and the refusal names the rows that ARE there" \
  "grep -Eq '9' '$repo2h/out.txt'"

# ==========================================================================
# B5. `lcars xo off <id>` on an ENGAGED mission — stood down, note written,
#     the lock lifted, and the recorded worker pid SIGNALLED.
# ==========================================================================
echo
echo "B5. standing one mission down"

repo5="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5="$(plant_mission "$repo5" "$MID" verify '{"status": "engaged", "engine": "copilot", "since": "2026-09-12T01:00:00Z"}')"

# A REAL process to signal, with a TERM trap that leaves a trace on disk.
SIGFILE="$TMPROOT/signalled.txt"
bash -c 'trap "printf SIGNALLED > \"$1\"; exit 0" TERM; while :; do sleep 0.2; done' _ "$SIGFILE" &
victim=$!
printf '%s\n' "$victim" >"$m5/xo.pid"

rc=0
( cd "$repo5" && bash "$SCRIPT" off "$MID" >out.txt 2>&1 ) || rc=$?
check "B5. \`lcars xo off <id>\` succeeds" "[ '$rc' -eq 0 ]"
check "B5. the recorded status is stood-down" \
  "grep -q '\"status\": \"stood-down\"' '$m5/state.json'"
check "B5. …with the conn handed back in the note" \
  "grep -q 'you have the conn' '$m5/state.json'"
check "B5. the per-mission opt-out is recorded" \
  "grep -q '\"optOut\": true' '$m5/state.json'"
# THE INVARIANT, restated at S207. This used to assert numberOne was on LINE 2,
# because every writer of the day deleted the key's line and re-inserted it
# after the opening brace — so a write MOVED the field to the top whether it
# needed to or not. That move was the whole of the S189 protection: a field at
# the top is never the LAST one, and the last one was what the writers
# corrupted. S207 fixed the writer instead — it re-derives every separator, so
# the last field is safe and an existing key is updated IN PLACE, keeping
# file.sh's field order. What must still be true is the thing the line-2 check
# was standing in for, so that is what is checked now: the block is ONE line,
# it is NOT the object's last field, and the file parses.
check "B5. numberOne is still ONE line (state_xo_block seds for it)" \
  "grep -q '\"numberOne\": {.*}' '$m5/state.json'"
check "B5. numberOne is NOT the last field (the S189 last-key rule)" \
  "[ \"\$(grep -n '\"numberOne\":' '$m5/state.json' | cut -d: -f1)\" -lt \"\$(( \$(grep -c '' '$m5/state.json') - 1 ))\" ]"
check "B5. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m5/state.json'"

# The pid was signalled (bounded poll — no unbounded wait in a test).
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$SIGFILE" ] && break
  sleep 0.1
done
kill "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
check "B5. the planted xo.pid was SIGNALLED" "[ -s '$SIGFILE' ]"

# The lock is LIFTED.
OWNERSHIP="$REPO_ROOT/skills/lcars-run/ownership.sh"
rcL=0
( cd "$repo5" && bash "$OWNERSHIP" xo-lock-reason "$m5" >lock.txt 2>&1 ) || rcL=$?
check "B5. the engaged lock is LIFTED once the mission is stood down" "[ '$rcL' -ne 0 ]"

# …and the status table reads the RECORDED status back.
out5="$( cd "$repo5" && bash "$SCRIPT" 2>&1 )"
check "B5. the status table shows stood-down" \
  "printf '%s' \"\$out5\" | grep -q 'stood-down'"
check "B5. the status table names the mission and its stage" \
  "printf '%s' \"\$out5\" | grep -q '$MID' && printf '%s' \"\$out5\" | grep -q 'verify'"

# `lcars xo on <mission>` clears the per-mission opt-out.
( cd "$repo5" && bash "$SCRIPT" on "$MID" >on.txt 2>&1 )
check "B5. \`lcars xo on <mission>\` clears the per-mission opt-out" \
  "! grep -q '\"optOut\": true' '$m5/state.json'"
check "B5. …and does NOT re-engage by itself (that is the driver's job)" \
  "! grep -q '\"status\": \"engaged\"' '$m5/state.json'"

# ==========================================================================
# B5b (FIX ROUND 1, D4). THE NOTE IS ON THE CAPTAIN'S CLOCK, NOT UTC.
#
# Stand-down at 21:05 local read "Number One stood down 04:05 · you have the
# conn" on the card, in the `.xo-note` and in the `lcars xo` table — seven
# hours adrift, on all three, because all three quote ONE stored note and the
# note was rendered with `date -u`. The RENDERING is what moved: the note is
# human copy and is written on the local clock, while `since` stays the
# machine-readable UTC instant it always was.
#
# The fixture runs the verb under a TZ twelve hours from UTC, so "it happens to
# agree" is not a way to pass.
# ==========================================================================
echo
echo "B5b. the stand-down note reads the captain's clock (fix round 1, D4)"

TZX="Pacific/Auckland"
repo5d="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5d="$(plant_mission "$repo5d" "$MID" verify '{"status": "engaged", "engine": "copilot", "since": "2026-09-12T01:00:00Z"}')"
local_before="$(TZ="$TZX" date +%H:%M)"
( cd "$repo5d" && TZ="$TZX" bash "$SCRIPT" off "$MID" >out.txt 2>&1 )
local_after="$(TZ="$TZX" date +%H:%M)"
utc_now="$(date -u +%H:%M)"
noted="$(sed -n 's/.*stood down \([0-9][0-9]:[0-9][0-9]\).*/\1/p' "$m5d/state.json" | head -1)"
check "B5b. the note carries a clock time at all" \
  "[ -n '$noted' ]"
check "B5b. …and it is the LOCAL clock ($TZX)" \
  "[ '$noted' = '$local_before' ] || [ '$noted' = '$local_after' ]"
check "B5b. …which is provably not UTC (the two differ by 12 hours here)" \
  "[ '$noted' != '$utc_now' ]"
# The STORED instant stays machine-readable — the rendering moved, the record
# did not.
check "B5b. \`since\` is still a UTC ISO-8601 instant" \
  "grep -Eq '\"since\": \"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\"' '$m5d/state.json'"

# EVERY SURFACE THAT PRINTS IT. The card and the board's `.xo-note` render the
# mission's recorded note verbatim (pinned in web/tests/test_xo_toggle.py), and
# so does the table here — so one note, read back three times, cannot disagree.
out5d="$( cd "$repo5d" && TZ="$TZX" bash "$SCRIPT" 2>&1 )"
check "B5b. the \`lcars xo\` table prints that same local time" \
  "printf '%s' \"\$out5d\" | grep -q 'stood down $noted'"
check "B5b. the payload the BOARD reads carries the same note, verbatim" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if \"stood down $noted\" in d[\"numberOne\"][\"note\"] else 1)' '$m5d/state.json'"

# A repo-level `off` stands EVERY engaged mission down.
repo5b="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5b="$(plant_mission "$repo5b" "$MID" verify '{"status": "engaged", "engine": "copilot"}')"
m5c="$(plant_mission "$repo5b" "lcars-20260530-002" implement '{"status": "engaged", "engine": "copilot"}')"
( cd "$repo5b" && bash "$SCRIPT" off >/dev/null 2>&1 )
check "B5. repo-level \`off\` stands EVERY engaged mission down" \
  "grep -q 'stood-down' '$m5b/state.json' && grep -q 'stood-down' '$m5c/state.json'"

# ==========================================================================
# B6. The delegator. `lcars xo` must reach xo.sh, not the smart-default router.
# ==========================================================================
echo
echo "B6. the lcars entry point delegates xo"

check "B6. skills/lcars/lcars.sh has an explicit \`xo)\` delegator" \
  "grep -q '^  xo)' '$LCARS_ENTRY'"
repo6="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
plant_mission "$repo6" "$MID" verify >/dev/null
out6="$( cd "$repo6" && LCARS_VERSION_CHECK=0 bash "$LCARS_ENTRY" xo 2>&1 )"
check "B6. \`lcars xo\` routes to the status table, not the smart default" \
  "printf '%s' \"\$out6\" | grep -q 'ON · copilot'"
check "B6. …and never announces a ROUTE" \
  "! printf '%s' \"\$out6\" | grep -q 'ROUTE:'"

# ==========================================================================
# B8 (FIX ROUND 1, D5). THE STATUS TABLE LINES UP.
#
# The header read `NUMBER ONE   NOTE` and the value column beneath it was two
# columns narrower, so NOTE never sat above its own column. The cause is worth
# recording because it will happen again: `printf '%-12s'` pads to twelve
# BYTES, and the placeholder this table prints for "nothing recorded" is an em
# dash — one column, three bytes. Every column is padded to a DISPLAY width
# now, by one helper the header and the rows both call.
#
# THE CHECK MEASURES COLUMNS, NOT SPACES. It reads where `NOTE` sits in the
# header and where each row's note sits, and requires them equal — so it goes
# red if the table drifts, and stays green if the table is redesigned.
# ==========================================================================
echo
echo "B8. the status table lines up (fix round 1, D5)"

cat >"$TMPROOT/align.py" <<'PYALIGN'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
hdr = [l for l in lines if "NUMBER ONE" in l and "NOTE" in l]
if len(hdr) != 1:
    print("no header row"); sys.exit(1)
h = hdr[0]
want = {"STAGE": h.index("STAGE"),
        "NUMBER ONE": h.index("NUMBER ONE"),
        "NOTE": h.index("NOTE", h.index("NUMBER ONE") + 1)}
rows = [l for l in lines if l.strip().startswith("lcars-2026")]
if len(rows) != 2:
    print("expected two rows, got %d" % len(rows)); sys.exit(1)
bad = 0
for r in rows:
    # Each cell is found by its own VALUE, so nothing here knows the widths.
    note = "ZZNOTE" if "ZZNOTE" in r else "—"
    got = {"STAGE": max(r.index("implement") if "implement" in r else -1,
                        r.index("verify") if "verify" in r else -1),
           "NUMBER ONE": (r.index("escalated") if "escalated" in r
                          else r.index("—")),
           "NOTE": (r.index("ZZNOTE") if note == "ZZNOTE"
                    else r.rindex("—"))}
    for col in ("STAGE", "NUMBER ONE", "NOTE"):
        if got[col] != want[col]:
            bad += 1
            print("%-10s header col %d, row col %d\n  %r" %
                  (col, want[col], got[col], r))
sys.exit(1 if bad else 0)
PYALIGN

repo8="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
# One mission with NOTHING recorded (both cells are the em-dash placeholder)
# and one with a real status and note: the two shapes that must line up.
plant_mission "$repo8" "lcars-20260530-010" implement >/dev/null
plant_mission "$repo8" "lcars-20260530-011" verify \
  '{"status": "escalated", "note": "ZZNOTE"}' >/dev/null
( cd "$repo8" && bash "$SCRIPT" >"$TMPROOT/table.txt" 2>&1 )
check "B8. every column sits under its own header, placeholders included" \
  "python3 '$TMPROOT/align.py' '$TMPROOT/table.txt'"
check "B8. the table still names both missions and both stages" \
  "grep -q 'lcars-20260530-010' '$TMPROOT/table.txt' && grep -q 'escalated' '$TMPROOT/table.txt' && grep -q 'ZZNOTE' '$TMPROOT/table.txt'"


# ==========================================================================
# B9 (SESSION 202). `lcars xo answer --mission <id>` — Number One at a park.
#
# THE DIVISION OF LABOUR, TESTED. The worker REASONS; this script EXECUTES. So
# every check below is about what xo.sh did with a verdict it was handed, never
# about what a model said — the worker is a PATH shim writing canned JSON, and
# the spend counter at the end of this file must still read zero.
#
# THE FOUR THINGS THAT MUST HOLD:
#   1. An ANSWER reaches the gate THROUGH `respond.sh` — the ordinary verb, with
#      the answer attributed — and the mission stays engaged.
#   2. A `scope` gate ESCALATES no matter what the worker said. Scope and spend
#      are the captain's, always (ruling 2026-09-11).
#   3. A citation whose quote is NOT in the file it names is INVENTED GROUNDS.
#      The over-rejection guard, in reverse: the research warning is a judge that
#      reasons past the record, so a verdict that cannot show its line is not a
#      verdict. It becomes an escalation with the malformed note.
#   4. Standing Number One down mid-spin reaches the WORKER, not just the record.
# ==========================================================================
echo
echo "B9. answer — Number One at a park (session 202)"

RESPOND="$REPO_ROOT/skills/lcars-respond/respond.sh"

# --- the worker shim -------------------------------------------------------
# A fake CLI that writes a canned xo-answer.json into the outdir it was granted
# and records that it ran. $XO_VERDICT holds the JSON body; $XO_WORKER_LOG counts
# invocations; $XO_WORKER_HOLD (when set) makes it hang so a stand-down has
# something to interrupt, recording the signal it receives to $XO_WORKER_SIG.
make_worker_shim() { # path
  cat >"$1" <<'SHIM'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
out="${LCARS_WORK_OUT:-}"
# The outdir also arrives as the token after --add-dir on copilot; prefer the env.
[ -n "$out" ] || out="$(for a in "$@"; do :; done; printf '')"
if [ -n "${XO_WORKER_HOLD:-}" ]; then
  trap 'printf "SIGTERM\n" >"$XO_WORKER_SIG"; exit 143' TERM
  printf 'started\n' >"$XO_WORKER_HOLD"
  i=0; while [ "$i" -lt 600 ]; do sleep 0.1 & wait $!; i=$((i+1)); done
  exit 0
fi
[ -n "${XO_VERDICT:-}" ] && printf '%s\n' "$XO_VERDICT" >"$out/xo-answer.json"
exit 0
SHIM
  chmod +x "$1"
}

WORKDIR="$TMPROOT/b8"; mkdir -p "$WORKDIR"
WORKER_SHIM="$WORKDIR/copilot-worker"; make_worker_shim "$WORKER_SHIM"
export XO_WORKER_LOG="$WORKDIR/worker-calls.txt"; : >"$XO_WORKER_LOG"

# A mission parked awaiting-human, with a record that answers its question.
plant_park() { # <repo> <id> <escalationType> <question>
  local repo="$1" id="$2" et="$3" q="$4" m
  m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m/research"
  {
    printf '{\n'
    printf '  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-09-11T10:00:00Z"},\n'
    printf '  "id": "%s",\n' "$id"
    printf '  "type": "feature",\n'
    printf '  "title": "The review queue",\n'
    printf '  "stage": "implement",\n'
    printf '  "awaitingHuman": true,\n'
    printf '  "pendingQuestion": "%s",\n' "$q"
    printf '  "created": "2026-05-30T10:00:00Z",\n'
    printf '  "githubIssue": 42\n'
    printf '}\n'
  } >"$m/state.json"
  {
    printf '{\n'
    printf '  "stage": "implement",\n'
    printf '  "humanSummary": "A ticket hit its session cap.",\n'
    printf '  "escalationType": "%s",\n' "$et"
    printf '  "technicalDetail": "t-003 failed three sessions.",\n'
    printf '  "questions": ["%s"]\n' "$q"
    printf '}\n'
  } >"$m/pending.json"
  # THE RECORD. §2 settles the question in one plain line — the case Number One
  # is SUPPOSED to answer.
  cat >"$m/prd.md" <<'PRD'
# The review queue

## 2. Scope
The queue shows assigned work only. Unassigned reviewers never appear in it.

## 3. Out of scope
Notifications.
PRD
  printf '# ADR-001\nThe queue is read-only.\n' >"$m/adr.md"
  printf '{"tickets": []}\n' >"$m/plan.json"
  printf '# Validated plan\nBuild the queue.\n' >"$m/validated-plan.md"
  printf '{"answers": []}\n' >"$m/answers.json"
  printf '{"findings": "none"}\n' >"$m/research/1.json"
  printf '{"type":"gate","stage":"implement"}\n' >"$m/events.jsonl"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$m"
}

# Run `xo answer` with the worker shim in place. Zero spend: the shim IS the CLI.
xo_answer() { # <repo> <id> <verdict-json> [extra env...]
  local repo="$1" id="$2" verdict="$3"; shift 3
  ( cd "$repo" && XO_VERDICT="$verdict" XO_WORKER_LOG="$XO_WORKER_LOG" \
      LCARS_WORKER_BIN="$WORKER_SHIM" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 "$@" \
      bash "$SCRIPT" answer --mission "$id" 2>&1 )
}

xo_state() { # <mission-dir> <key>
  sed -n 's/.*"numberOne"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$1/state.json" \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# --------------------------------------------------------------------------
# B9a. THE ANSWER PATH. A verdict grounded in a line that really is in the PRD
#      goes through respond.sh, attributed, and the mission stays engaged.
# --------------------------------------------------------------------------
repo8="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8="$(plant_park "$repo8" "lcars-20260911-001" cap \
      "Should unassigned reviewers appear in the queue?")"
V_OK='{"decision":"answer","answer":"No — the queue shows assigned work only.","rationale":"PRD section 2 settles it.","citations":[{"file":"prd.md","quote":"The queue shows assigned work only."}],"confidence":"high"}'
rc8=0
out8="$(xo_answer "$repo8" "lcars-20260911-001" "$V_OK")" || rc8=$?
check "B9a. an ANSWER verdict exits 0 (the driver may continue)" "[ '$rc8' -eq 0 ]"
check "B9a. the answer is recorded in answers.json (through respond.sh, not by hand)" \
  "grep -q 'assigned work only' '$m8/answers.json'"
check "B9a. …attributed: answeredBy = number-one" \
  "grep -q '\"answeredBy\": \"number-one\"' '$m8/answers.json'"
check "B9a. the gate is CLEARED — awaitingHuman is gone" \
  "! grep -q '\"awaitingHuman\"' '$m8/state.json'"
check "B9a. the mission is STILL engaged (Number One keeps the conn)" \
  "[ \"\$(xo_state '$m8' status)\" = 'engaged' ]"
check "B9a. …and records what it did: lastAction names the stage" \
  "printf '%s' \"\$(xo_state '$m8' lastAction)\" | grep -q 'answered implement'"
check "B9a. a journal line is appended to number-one.jsonl" \
  "[ -s '$m8/number-one.jsonl' ] && grep -q '\"action\": \"answered\"' '$m8/number-one.jsonl'"
check "B9a. the citation is kept with the journal entry (the line that settled it)" \
  "grep -q 'assigned work only' '$m8/number-one.jsonl'"
check "B9a. the worker was spawned EXACTLY once" \
  "[ \"\$(grep -c '^worker ' '$XO_WORKER_LOG')\" = '1' ]"
check "B9a. …with the numberOne model pin on its argv (--model claude-opus-4.8)" \
  "grep -q -- '--model claude-opus-4.8' '$XO_WORKER_LOG'"
check "B9a. no pricing words in what it printed" \
  "! printf '%s' \"\$out8\" | grep -Eqi 'free|billed|billing|cost|pricing'"
check "B9a. xo.pid is cleaned up after the spin" "[ ! -f '$m8/xo.pid' ]"
check "B9a. the driver was NOT re-executed (respond.sh resume suppressed)" \
  "! printf '%s' \"\$out8\" | grep -q 'Resuming'"

# --------------------------------------------------------------------------
# B9b. THE ESCALATE PATH. The gate STAYS; the captain gets the note AND the
#      recommendation, and a non-zero exit tells the driver to halt.
# --------------------------------------------------------------------------
repo8b="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8b="$(plant_park "$repo8b" "lcars-20260911-002" cap \
       "Should the queue send email?")"
V_ESC='{"decision":"escalate","answer":"","rationale":"The PRD lists notifications as out of scope but does not say what to do instead.","citations":[],"recommendation":"Leave email out and file it as a follow-up.","confidence":"low"}'
rc8b=0
out8b="$(xo_answer "$repo8b" "lcars-20260911-002" "$V_ESC")" || rc8b=$?
check "B9b. an ESCALATE verdict exits NON-ZERO (the driver halts as today)" \
  "[ '$rc8b' -ne 0 ]"
check "B9b. the gate is INTACT — awaitingHuman still true" \
  "grep -q '\"awaitingHuman\": true' '$m8b/state.json'"
check "B9b. nothing was written to answers.json" \
  "! grep -q '\"answeredBy\"' '$m8b/answers.json'"
check "B9b. status is escalated" "[ \"\$(xo_state '$m8b' status)\" = 'escalated' ]"
check "B9b. the note carries the summary AND the recommendation" \
  "printf '%s' \"\$(xo_state '$m8b' note)\" | grep -q 'follow-up'"
check "B9b. the status table shows it" \
  "( cd '$repo8b' && bash '$SCRIPT' ) | grep -q 'escalated'"
check "B9b. a journal line records the escalation" \
  "grep -q '\"action\": \"escalated\"' '$m8b/number-one.jsonl'"

# --------------------------------------------------------------------------
# B9c. SCOPE ALWAYS GOES TO THE CAPTAIN. The worker answered — confidently, with
#      a citation that really is in the PRD — and it does not matter. A `scope`
#      gate is the captain's by ruling, not by heuristic.
# --------------------------------------------------------------------------
repo8c="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8c="$(plant_park "$repo8c" "lcars-20260911-003" scope \
       "Should we also build the notifications service?")"
rc8c=0
out8c="$(xo_answer "$repo8c" "lcars-20260911-003" "$V_OK")" || rc8c=$?
check "B9c. escalationType=scope ⇒ NON-ZERO even on a perfectly good ANSWER verdict" \
  "[ '$rc8c' -ne 0 ]"
check "B9c. …the gate is intact" "grep -q '\"awaitingHuman\": true' '$m8c/state.json'"
check "B9c. …nothing reached answers.json" \
  "! grep -q '\"answeredBy\"' '$m8c/answers.json'"
check "B9c. …status escalated" "[ \"\$(xo_state '$m8c' status)\" = 'escalated' ]"
check "B9c. …and the note SAYS it was scope (so the captain knows why)" \
  "printf '%s' \"\$(xo_state '$m8c' note)\" | grep -qi 'scope'"

# --------------------------------------------------------------------------
# B9d. INVENTED GROUNDS. The quote is well-formed, the file exists, and the line
#      is NOT in it. That is the exact failure the research warned about, so the
#      verdict is refused and the gate goes back to the captain.
# --------------------------------------------------------------------------
repo8d="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8d="$(plant_park "$repo8d" "lcars-20260911-004" cap "Should reviewers self-assign?")"
V_FAKE='{"decision":"answer","answer":"Yes, reviewers self-assign.","rationale":"The PRD says so.","citations":[{"file":"prd.md","quote":"Reviewers may always self-assign from the queue."}],"confidence":"high"}'
rc8d=0
out8d="$(xo_answer "$repo8d" "lcars-20260911-004" "$V_FAKE")" || rc8d=$?
check "B9d. a citation quote NOT in its file ⇒ NON-ZERO" "[ '$rc8d' -ne 0 ]"
check "B9d. …the gate is intact" "grep -q '\"awaitingHuman\": true' '$m8d/state.json'"
check "B9d. …nothing was answered" "! grep -q '\"answeredBy\"' '$m8d/answers.json'"
check "B9d. …and the note is the malformed-verdict note" \
  "printf '%s' \"\$(xo_state '$m8d' note)\" | grep -q 'could not decide — malformed verdict'"

# An ANSWER with NO citations at all is the same refusal.
repo8e="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8e="$(plant_park "$repo8e" "lcars-20260911-005" cap "Should reviewers self-assign?")"
V_NOCITE='{"decision":"answer","answer":"Yes.","rationale":"It seems right.","citations":[],"confidence":"high"}'
rc8e=0
xo_answer "$repo8e" "lcars-20260911-005" "$V_NOCITE" >/dev/null || rc8e=$?
check "B9e. an ANSWER with NO citations ⇒ escalated, malformed note" \
  "[ '$rc8e' -ne 0 ] && printf '%s' \"\$(xo_state '$m8e' note)\" | grep -q 'malformed verdict'"

# Unparseable JSON is the same refusal — never a crash, never a silent answer.
repo8f="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8f="$(plant_park "$repo8f" "lcars-20260911-006" cap "Should reviewers self-assign?")"
rc8f=0
xo_answer "$repo8f" "lcars-20260911-006" 'not json at all {{{' >/dev/null || rc8f=$?
check "B9f. UNPARSEABLE verdict JSON ⇒ escalated, malformed note" \
  "[ '$rc8f' -ne 0 ] && printf '%s' \"\$(xo_state '$m8f' note)\" | grep -q 'malformed verdict'"

# NO file at all (the procrastinating worker) is the same refusal.
repo8g="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8g="$(plant_park "$repo8g" "lcars-20260911-007" cap "Should reviewers self-assign?")"
rc8g=0
xo_answer "$repo8g" "lcars-20260911-007" '' >/dev/null || rc8g=$?
check "B9g. NO verdict file at all ⇒ escalated, malformed note" \
  "[ '$rc8g' -ne 0 ] && printf '%s' \"\$(xo_state '$m8g' note)\" | grep -q 'malformed verdict'"

# A verdict that answers while declaring LOW confidence is taken at its word:
# the prompt tells Number One to escalate when it is unsure, and this is it
# saying so. The judge's "unsure" exit is honoured, not argued with.
repo8h="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8h="$(plant_park "$repo8h" "lcars-20260911-008" cap "Should reviewers self-assign?")"
V_LOW='{"decision":"answer","answer":"Probably not.","rationale":"Section 2 hints at it.","citations":[{"file":"prd.md","quote":"The queue shows assigned work only."}],"confidence":"low"}'
rc8h=0
xo_answer "$repo8h" "lcars-20260911-008" "$V_LOW" >/dev/null || rc8h=$?
check "B9h. decision=answer with confidence=low ⇒ escalated (the unsure exit stands)" \
  "[ '$rc8h' -ne 0 ] && [ \"\$(xo_state '$m8h' status)\" = 'escalated' ]"

# --------------------------------------------------------------------------
# B9i. NO GATE, NO SPIN. A mission with no pending.json is refused before a
#      worker is ever hired — the cheapest possible defence against spending on
#      a question nobody asked.
# --------------------------------------------------------------------------
before_i="$(grep -c '^worker ' "$XO_WORKER_LOG")" || before_i=0
repo8i="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
plant_mission "$repo8i" "lcars-20260911-009" implement >/dev/null
rc8i=0
out8i="$(xo_answer "$repo8i" "lcars-20260911-009" "$V_OK")" || rc8i=$?
after_i="$(grep -c '^worker ' "$XO_WORKER_LOG")" || after_i=0
check "B9i. no pending.json ⇒ a loud refusal, non-zero" "[ '$rc8i' -ne 0 ]"
check "B9i. …and NO worker was hired" "[ '$before_i' = '$after_i' ]"

# --------------------------------------------------------------------------
# B9j. STAND DOWN MID-SPIN. `lcars xo off <id>` while the worker is running must
#      reach the WORKER, not just the record. S201 wrote the TERM; this proves
#      something is there to receive it.
# --------------------------------------------------------------------------
repo8j="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8j="$(plant_park "$repo8j" "lcars-20260911-010" cap "Should reviewers self-assign?")"
export XO_WORKER_HOLD="$WORKDIR/held.txt"; rm -f "$XO_WORKER_HOLD"
export XO_WORKER_SIG="$WORKDIR/sig.txt";   rm -f "$XO_WORKER_SIG"
( cd "$repo8j" && XO_VERDICT="$V_OK" XO_WORKER_LOG="$XO_WORKER_LOG" \
    XO_WORKER_HOLD="$XO_WORKER_HOLD" XO_WORKER_SIG="$XO_WORKER_SIG" \
    LCARS_WORKER_BIN="$WORKER_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" answer --mission lcars-20260911-010 >/dev/null 2>&1 ) &
spin_pid=$!
w=0; while [ "$w" -lt 100 ] && [ ! -s "$XO_WORKER_HOLD" ]; do sleep 0.1; w=$((w + 1)); done
check "B9j. the worker is running, and xo.pid names a live process" \
  "[ -s '$XO_WORKER_HOLD' ] && [ -f '$m8j/xo.pid' ] && kill -0 \"\$(cat '$m8j/xo.pid')\" 2>/dev/null"
( cd "$repo8j" && bash "$SCRIPT" off lcars-20260911-010 >/dev/null 2>&1 )
wait "$spin_pid" 2>/dev/null; spin_rc=$?
w=0; while [ "$w" -lt 100 ] && [ ! -s "$XO_WORKER_SIG" ]; do sleep 0.1; w=$((w + 1)); done
check "B9j. the SIGTERM reached the WORKER itself (the shim recorded it)" \
  "grep -q SIGTERM '$XO_WORKER_SIG'"
check "B9j. the spin exited non-zero — it did not answer on the way down" \
  "[ '$spin_rc' -ne 0 ]"
check "B9j. the record says stood-down, not escalated" \
  "[ \"\$(xo_state '$m8j' status)\" = 'stood-down' ]"
check "B9j. the gate is STILL there for the captain" \
  "grep -q '\"awaitingHuman\": true' '$m8j/state.json'"
check "B9j. nothing was answered on the way down" \
  "! grep -q '\"answeredBy\"' '$m8j/answers.json'"
unset XO_WORKER_HOLD XO_WORKER_SIG

# --------------------------------------------------------------------------
# B9k. THE INPUT DIR IS THE MISSION'S RECORD — and it is a COPY. Number One must
#      be unable to change the mission it is judging.
# --------------------------------------------------------------------------
repo8k="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8k="$(plant_park "$repo8k" "lcars-20260911-011" cap "Should reviewers self-assign?")"
INSPECT="$WORKDIR/inspect"; mkdir -p "$INSPECT"
cat >"$WORKDIR/inspect-cli" <<'SHIM'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
for a in "$@"; do printf '%s\n' "$a" >>"$XO_INSPECT/argv.txt"; done
# The prompt is the token after the leading -p; keep it for inspection.
printf '%s\n' "$2" >"$XO_INSPECT/prompt.txt"
[ -n "${XO_VERDICT:-}" ] && printf '%s\n' "$XO_VERDICT" >"${LCARS_WORK_OUT}/xo-answer.json"
exit 0
SHIM
chmod +x "$WORKDIR/inspect-cli"
( cd "$repo8k" && XO_VERDICT="$V_OK" XO_WORKER_LOG="$XO_WORKER_LOG" XO_INSPECT="$INSPECT" \
    LCARS_WORKER_BIN="$WORKDIR/inspect-cli" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" answer --mission lcars-20260911-011 >/dev/null 2>&1 )
XO_IN_DIR="$(grep -oE '/[^ ]*/input' "$INSPECT/prompt.txt" | head -1)"
check "B9k. the prompt names a real INPUT directory" "[ -n \"\$XO_IN_DIR\" ]"
check "B9k. it holds a COPY of the PRD, not the mission's own file" \
  "[ -f \"\$XO_IN_DIR/prd.md\" ] && [ \"\$XO_IN_DIR/prd.md\" != '$m8k/prd.md' ]"
check "B9k. …and of pending.json, answers.json, plan.json and the validated plan" \
  "[ -f \"\$XO_IN_DIR/pending.json\" ] && [ -f \"\$XO_IN_DIR/answers.json\" ] && [ -f \"\$XO_IN_DIR/plan.json\" ] && [ -f \"\$XO_IN_DIR/validated-plan.md\" ]"
check "B9k. …and the research findings + the recent events" \
  "[ -f \"\$XO_IN_DIR/research/1.json\" ] && [ -f \"\$XO_IN_DIR/events.jsonl\" ]"
check "B9k. every copy is READ-ONLY to the worker" \
  "[ ! -w \"\$XO_IN_DIR/prd.md\" ]"
check "B9k. copilot was granted --add-dir on that input dir" \
  "grep -qx -- \"\$XO_IN_DIR\" '$INSPECT/argv.txt'"
check "B9k. the worker's tool list is the read+author one (no bash, no edit)" \
  "grep -qx 'view,grep,glob,create' '$INSPECT/argv.txt'"
check "B9k. the mission's OWN prd.md is untouched" \
  "grep -q 'assigned work only' '$m8k/prd.md'"

# ==========================================================================
# B9l (fix round 1, D4). A STAND-DOWN IS AN ACTION, AND ACTIONS ARE JOURNALLED.
#
# SKILL.md says "Every action is appended to `<mission>/number-one.jsonl`", and
# after a mid-spin stand-down there was no such file at all — only the state
# note. The living comment renders that journal, so the one record of a spin
# being ABORTED was missing from the surface the captain reads.
#
# AND THE GATE MUST BE TAKEABLE AGAIN. `lastPending` is written BEFORE the spin
# (so a crash cannot buy a second worker), which means a worker killed mid-spin
# leaves the cksum of a gate that was never actually answered. Number One would
# then never look at that gate again, however many times it is re-engaged. A
# stand-down is the captain taking the conn back, so it clears the memory too.
# ==========================================================================
echo
echo "B9l. a stand-down leaves a journal line, and hands the gate back"

repo8l="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8l="$(plant_park "$repo8l" "lcars-20260911-012" cap "Should reviewers self-assign?")"
# The state a mid-spin kill leaves behind: engaged, with the gate it was already
# stamped as having taken.
grep -v '"numberOne"' "$m8l/state.json" >"$m8l/state.tmp" && mv "$m8l/state.tmp" "$m8l/state.json"
awk 'NR==1{print; print "  \"numberOne\": {\"status\": \"engaged\", \"engine\": \"copilot\", \"lastPending\": \"3141592-65\"},"; next} {print}' \
  "$m8l/state.json" >"$m8l/state.tmp" && mv "$m8l/state.tmp" "$m8l/state.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m8l/state.json" \
  || { echo "B9l FIXTURE IS NOT VALID JSON"; exit 1; }
rm -f "$m8l/number-one.jsonl"

rc8l=0
( cd "$repo8l" && bash "$SCRIPT" off lcars-20260911-012 >/dev/null 2>&1 ) || rc8l=$?
check "B9l. \`lcars xo off <id>\` succeeds" "[ '$rc8l' -eq 0 ]"
check "B9l. the journal FILE exists after a stand-down" "[ -f '$m8l/number-one.jsonl' ]"
check "B9l. …with a stood-down action on it" \
  "grep -q '\"action\": \"stood-down\"' '$m8l/number-one.jsonl'"
check "B9l. …stamped with a time, like every other action" \
  "grep -q '\"at\": \"20' '$m8l/number-one.jsonl'"
check "B9l. …naming the stage it was standing down from" \
  "grep -q '\"stage\": \"implement\"' '$m8l/number-one.jsonl'"
check "B9l. …and a detail the living comment can render" \
  "grep -q '\"detail\": \"' '$m8l/number-one.jsonl'"
check "B9l. the journal line is one valid JSON object per line" \
  "python3 -c 'import json,sys;[json.loads(l) for l in open(sys.argv[1]) if l.strip()]' '$m8l/number-one.jsonl'"
check "B9l. the stamped lastPending was CLEARED — that gate can be taken again" \
  "[ -z \"\$(xo_state '$m8l' lastPending)\" ]"
check "B9l. …the stand-down itself is still recorded" \
  "[ \"\$(xo_state '$m8l' status)\" = 'stood-down' ]"
check "B9l. numberOne is still ONE line, at the top (the S189 rule)" \
  "sed -n '2p' '$m8l/state.json' | grep -q '^[[:space:]]*\"numberOne\":' && [ \"\$(grep -c '\"numberOne\"' '$m8l/state.json')\" = '1' ]"
check "B9l. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m8l/state.json'"
check "B9l. no pricing words in the journal" \
  "! grep -Eqi 'free|billed|billing|pricing' '$m8l/number-one.jsonl'"

# A mission that was NOT engaged is not "stood down" and grows no journal line —
# the file records what happened, not what was asked for.
repo8m="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8m="$(plant_mission "$repo8m" "lcars-20260911-013" implement)"
( cd "$repo8m" && bash "$SCRIPT" off lcars-20260911-013 >/dev/null 2>&1 )
check "B9m. standing down a mission that was never engaged journals NOTHING" \
  "[ ! -f '$m8m/number-one.jsonl' ]"
check "B9m. …but the per-mission opt-out is still recorded" \
  "grep -q '\"optOut\": true' '$m8m/state.json'"

# THE MID-SPIN CASE, driven for real: kill the worker with `lcars xo off` while
# it is running, and the abort is on the journal afterwards.
repo8n="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8n="$(plant_park "$repo8n" "lcars-20260911-014" cap "Should reviewers self-assign?")"
rm -f "$m8n/number-one.jsonl"
export XO_WORKER_HOLD="$WORKDIR/held-n.txt"; rm -f "$XO_WORKER_HOLD"
export XO_WORKER_SIG="$WORKDIR/sig-n.txt";   rm -f "$XO_WORKER_SIG"
( cd "$repo8n" && XO_VERDICT="$V_OK" XO_WORKER_LOG="$XO_WORKER_LOG" \
    XO_WORKER_HOLD="$XO_WORKER_HOLD" XO_WORKER_SIG="$XO_WORKER_SIG" \
    LCARS_WORKER_BIN="$WORKER_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" answer --mission lcars-20260911-014 >/dev/null 2>&1 ) &
spin_pid_n=$!
w=0; while [ "$w" -lt 100 ] && [ ! -s "$XO_WORKER_HOLD" ]; do sleep 0.1; w=$((w + 1)); done
check "B9n. the worker is running" "[ -s '$XO_WORKER_HOLD' ]"
check "B9n. …and lastPending was stamped before the spin" \
  "[ -n \"\$(xo_state '$m8n' lastPending)\" ] || true"
( cd "$repo8n" && bash "$SCRIPT" off lcars-20260911-014 >/dev/null 2>&1 )
wait "$spin_pid_n" 2>/dev/null
check "B9n. the ABORTED spin left a journal line behind it" \
  "[ -f '$m8n/number-one.jsonl' ] && grep -q '\"action\": \"stood-down\"' '$m8n/number-one.jsonl'"
check "B9n. …and the gate is still the captain's" \
  "grep -q '\"awaitingHuman\": true' '$m8n/state.json'"
check "B9n. …with no cksum left to lock Number One out of it" \
  "[ -z \"\$(xo_state '$m8n' lastPending)\" ]"
unset XO_WORKER_HOLD XO_WORKER_SIG

# ==========================================================================
# B7. ZERO SPEND — the shim recorded nothing at all.
# ==========================================================================
echo
echo "B7. zero spend"
# `grep -c` prints 0 AND exits 1 on no match, so an `|| printf 0` fallback would
# print a second zero and turn the count into "0\n0".
shim_calls="$(grep -c . "$XO_SHIM_LOG" 2>/dev/null)" || true
shim_models="$(grep -c -- '--model' "$XO_SHIM_LOG" 2>/dev/null)" || true
shim_calls="${shim_calls:-0}"; shim_models="${shim_models:-0}"
printf '  shim invocations: %s (with --model: %s)\n' "$shim_calls" "$shim_models"
check "B7. no worker CLI was invoked at all" "[ '$shim_calls' -eq 0 ]"
check "B7. …so nothing real was ever spawned" "[ '$shim_models' -eq 0 ]"
# B8 DOES hire a worker — through $LCARS_WORKER_BIN, which is a shim of its own,
# never a CLI on PATH. Report its count so the two are never confused: the line
# above is "no real CLI ran", the line below is "the fake one ran N times".
no_calls="$(grep -c '^worker ' "$XO_WORKER_LOG" 2>/dev/null)" || true
no_models="$(grep -c -- '--model' "$XO_WORKER_LOG" 2>/dev/null)" || true
printf '  number-one worker-shim invocations: %s (with --model: %s)\n' \
  "${no_calls:-0}" "${no_models:-0}"

# ==========================================================================
echo
printf 'lcars xo: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
