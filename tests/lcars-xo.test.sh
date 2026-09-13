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
check "B5. numberOne sits at the TOP of state.json (the S189 last-key rule)" \
  "sed -n '2p' '$m5/state.json' | grep -q '^[[:space:]]*\"numberOne\":'"
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
check "B7. …so nothing could have billed" "[ '$shim_models' -eq 0 ]"

# ==========================================================================
echo
printf 'lcars xo: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
