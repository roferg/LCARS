#!/usr/bin/env bash
#
# S223 fold-in (High, real data loss): `lcars xo off` must never corrupt
# state.json, whatever prose a verdict's headline carries. A fast, scoped
# suite of its own — lcars-xo.test.sh is long, and this proof must be cheap to
# run on every change to the numberOne reader/writer.
#
# The oracle is a real JSON parser (python3), never a grep.
#
# Usage: bash tests/lcars-xo-state-json.test.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/lcars-xo/xo.sh"
STATE_LIB="$REPO_ROOT/skills/lcars-init/lcars-state.sh"
MID="lcars-20260530-001"
pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS=
export LCARS_VERSION_STAMP="$TMPROOT/stamp"
# NOTHING here may reach a model or GitHub: fake both engines and gh.
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
for b in claude copilot gh; do
  printf '#!/bin/sh\necho "$0 $*" >>"%s/shim.log"\nexit 1\n' "$TMPROOT" >"$SHIM/$b"; chmod +x "$SHIM/$b"
done
export PATH="$SHIM:$PATH" LCARS_GH_BIN="$SHIM/gh" LCARS_CLAUDE_BIN="$SHIM/claude"
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

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


# ---------------------------------------------------------------------------
# The primitives themselves: braces, quotes, backslashes, newlines.
# ---------------------------------------------------------------------------
echo "S223 — the numberOne reader/writer is JSON-aware"
. "$STATE_LIB"
O='{"status": "engaged", "headline": "a } b \" {c\\", "n": 3}'
check "P1. json1_get reads a string holding } and \" back exactly" \
  "[ \"\$(lcars_json1_get \"\$O\" headline)\" = 'a } b \" {c\\' ]"
check "P2. json1_get reads the key AFTER a braced value" \
  "[ \"\$(lcars_json1_raw \"\$O\" n)\" = 3 ]"
check "P3. json1_set on a braced object yields VALID JSON with every key" \
  "python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d==dict(status=\"stood-down\",headline=\"a } b \\\" {c\\\\\",n=3)' \"\$(lcars_json1_set \"\$O\" status '\"stood-down\"')\""
check "P4. json1_del on a braced object yields VALID JSON" \
  "python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d==dict(status=\"engaged\",n=3)' \"\$(lcars_json1_del \"\$O\" headline)\""
check "P5. json1_str escapes a newline so the object stays ONE line" \
  "[ \"\$(lcars_json1_str 'a
b' | wc -l | tr -d ' ')\" = 0 ] && python3 -c 'import json,sys; assert json.loads(sys.argv[1])==\"a\\nb\"' \"\$(lcars_json1_str 'a
b')\""
f="$TMPROOT/s.json"
printf '{\n  "id": "x",\n  "numberOne": %s,\n  "title": "t"\n}\n' "$O" >"$f"
check "P6. lcars_state_xo_block returns the WHOLE object off a state.json" \
  "[ \"\$(lcars_state_xo_block '$f')\" = \"\$O\" ]"
echo

# B5z (S223, fold-in — High, real data loss). `lcars xo off <id>` CORRUPTED the
#     captain's real state.json: `state_xo_block` read the numberOne object with
#     `{[^}]*}`, which stops at the first `}` INSIDE a value — and a verdict's
#     headline is prose that can hold one. The read came back truncated, the
#     write put the truncated object back, and the rest of the line was lost.
#     Every numberOne read/write now goes through the brace- and quote-aware
#     reader in lcars-state.sh. The oracle is a real JSON parser.
# ==========================================================================
echo
echo "B5z. a headline with braces and quotes survives a stand-down (S223)"
repo5z="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
HL5Z='I could not check {the point} — it said "LOW \\ {x}" and stopped }'
XO5Z="$(python3 -c 'import json,sys; print(json.dumps({"status":"engaged","engine":"copilot","since":"2026-09-12T01:00:00Z","score":"low","headline":sys.argv[1],"meaning":"a } b { c","lastAction":"looked 07:02"}))' "$HL5Z")"
m5z="$(plant_mission "$repo5z" "$MID" verify "$XO5Z")"
rc=0
( cd "$repo5z" && bash "$SCRIPT" off "$MID" >out.txt 2>&1 ) || rc=$?
check "B5z. \`lcars xo off <id>\` succeeds with braces + quotes in the headline" "[ '$rc' -eq 0 ]"
check "B5z. state.json is STILL VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m5z/state.json' 2>/dev/null"
check "B5z. the headline survives byte-for-byte" \
  "[ \"\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"numberOne\"][\"headline\"])' '$m5z/state.json')\" = \"\$(printf '%s' \"\$HL5Z\")\" ]"
check "B5z. the meaning (a } b { c) survives" \
  "python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))[\"numberOne\"][\"meaning\"]==\"a } b { c\"' '$m5z/state.json' 2>/dev/null"
check "B5z. the status is stood-down" \
  "python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))[\"numberOne\"][\"status\"]==\"stood-down\"' '$m5z/state.json' 2>/dev/null"
check "B5z. every OTHER key survives (title, stage, githubIssue, engine, score)" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"title\"]==\"Add dark mode\" and d[\"stage\"]==\"verify\" and d[\"githubIssue\"]==42 and d[\"numberOne\"][\"engine\"]==\"copilot\" and d[\"numberOne\"][\"score\"]==\"low\"' '$m5z/state.json' 2>/dev/null"
check "B5z. numberOne is still ONE line" \
  "[ \"\$(grep -c '\"numberOne\"' '$m5z/state.json')\" = 1 ]"
# …and a SECOND stand-down on the same file (the double-click) changes nothing
# that matters and still leaves valid JSON.
( cd "$repo5z" && bash "$SCRIPT" off "$MID" >out2.txt 2>&1 )
check "B5z. a second \`off\` on the same mission still leaves VALID JSON" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"numberOne\"][\"status\"]==\"stood-down\"' '$m5z/state.json' 2>/dev/null"
# The repo-level off walks every engaged mission — same hazard, same proof.
repo5y="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5y="$(plant_mission "$repo5y" "$MID" verify "$XO5Z")"
( cd "$repo5y" && bash "$SCRIPT" off >/dev/null 2>&1 )
check "B5z. repo-level \`off\` with a braced headline leaves VALID JSON" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"numberOne\"][\"status\"]==\"stood-down\" and d[\"numberOne\"][\"meaning\"]==\"a } b { c\"' '$m5y/state.json' 2>/dev/null"

# B5w (S223, fix round 1 — D4). THE SHAPE ON THE CAPTAIN'S DISK. B5z above
#     plants `numberOne` the way the harness writes it: ONE line. His own
#     state.json was REPAIRED BY HAND on 2026-09-19, and a hand-repaired file
#     is PRETTY-PRINTED — the object spread over several lines. The field
#     writer edits LINES, so it replaced only the first of them and left the
#     rest of the object dangling as top-level junk:
#         "numberOne": {…},
#           "headline": "…",        ← was inside the object
#         },                        ← a bare brace, now a "field"
#         "baseFreshness": {,       ← the next object's head, comma'd
#     …which is not JSON at all. Reproduced on 6/6 missions by the fresh
#     tester, WITH A PLAIN HEADLINE — so the braces are not even needed. The
#     read is JSON-aware; this is the WRITE.
# ==========================================================================
echo
echo "B5w. a PRETTY-PRINTED state.json survives a stand-down (S223 fix 1, D4)"
pretty_mission() { # <repo> <id> — numberOne spread over lines, like a hand repair
  local repo="$1" id="$2" m
  m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m"
  cat >"$m/state.json" <<'JSON'
{
  "id": "lcars-20260530-001",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "verify",
  "numberOne": {
    "status": "engaged",
    "engine": "copilot",
    "since": "2026-09-12T01:00:00Z",
    "score": "low",
    "headline": "I could not check {the point} — it said \"LOW\" and stopped }",
    "meaning": "a } b { c",
    "lastAction": "looked 07:02"
  },
  "baseFreshness": {
    "checkedAt": "2026-09-19T06:00:00Z",
    "behind": 0
  },
  "created": "2026-05-30T10:00:00Z",
  "githubIssue": 42
}
JSON
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$m"
}
repo5w="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5w="$(pretty_mission "$repo5w" "$MID")"
rc=0
( cd "$repo5w" && bash "$SCRIPT" off "$MID" >out.txt 2>&1 ) || rc=$?
check "B5w. \`lcars xo off <id>\` succeeds on a pretty-printed state.json" "[ '$rc' -eq 0 ]"
check "B5w. state.json is STILL VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m5w/state.json' 2>/dev/null"
check "B5w. the status is stood-down and the headline survives" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"numberOne\"]; assert d[\"status\"]==\"stood-down\", d; assert d[\"headline\"]==\"I could not check {the point} — it said \\\"LOW\\\" and stopped }\", d' '$m5w/state.json' 2>/dev/null"
check "B5w. the SIBLING object baseFreshness is intact (not \`{,\`)" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"baseFreshness\"]==dict(checkedAt=\"2026-09-19T06:00:00Z\",behind=0), d' '$m5w/state.json' 2>/dev/null"
check "B5w. every other key survives byte-intact" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"title\"]==\"Add dark mode\" and d[\"stage\"]==\"verify\" and d[\"githubIssue\"]==42 and d[\"created\"]==\"2026-05-30T10:00:00Z\" and d[\"type\"]==\"feature\"' '$m5w/state.json' 2>/dev/null"
# A PLAIN headline, pretty-printed: the tester's 6/6 case with no brace at all.
repo5v="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5v="$(pretty_mission "$repo5v" "$MID")"
python3 - "$m5v/state.json" <<'PY'
import json,sys
p=sys.argv[1]; t=open(p).read()
open(p,"w").write(t.replace(
  '"I could not check {the point} — it said \\"LOW\\" and stopped }"',
  '"All four routes rendered"'))
PY
( cd "$repo5v" && bash "$SCRIPT" off "$MID" >/dev/null 2>&1 )
check "B5w. a PLAIN headline, pretty-printed, also survives" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"numberOne\"][\"status\"]==\"stood-down\" and d[\"numberOne\"][\"headline\"]==\"All four routes rendered\" and d[\"baseFreshness\"][\"behind\"]==0' '$m5v/state.json' 2>/dev/null"
# …and a pretty-printed file the writer must ALSO be able to add a new key to.
check "B5w. a NEW top-level key lands in a pretty-printed file, still valid" \
  ". '$STATE_LIB'; lcars_state_set_string '$m5v/state.json' owner 'roferg'; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"owner\"]==\"roferg\" and d[\"baseFreshness\"][\"behind\"]==0' '$m5v/state.json'"


# ---------------------------------------------------------------------------
# D3 (S223 fix round 2) — AN ALREADY-BROKEN state.json IS REFUSED, NOT MANGLED
# ---------------------------------------------------------------------------
# A tester appended garbage to a state.json and ran `lcars xo off`. It printed
# "stood down on <id>" and exited 0 — while the file came back with a stray
# comma after every opening brace (`"baseFreshness": {,`). The write cannot
# succeed on a file nobody can parse, so it must SAY SO and leave it alone.
repo5x="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5x="$(pretty_mission "$repo5x" "$MID")"
printf 'this is not json\n' >>"$m5x/state.json"
before5x="$(cat "$m5x/state.json")"
rc5x=0
( cd "$repo5x" && bash "$SCRIPT" off "$MID" >out.txt 2>err.txt ) || rc5x=$?
check "D3. \`lcars xo off\` on an UNPARSEABLE state.json EXITS NON-ZERO" \
  "[ '$rc5x' -ne 0 ]"
check "D3. …and never claims it stood anything down" \
  "! grep -q 'stood down' '$repo5x/out.txt' '$repo5x/err.txt'"
check "D3. …says REFUSED, in plain English, naming the file" \
  "grep -q 'REFUSED' '$repo5x/err.txt' && grep -q \"\$(printf '%s' '$m5x/state.json')\" '$repo5x/err.txt'"
check "D3. …and tells him it is not valid JSON" \
  "grep -qi 'not valid JSON' '$repo5x/err.txt'"
check "D3. …and the file is left BYTE-IDENTICAL — never mangled further" \
  "[ \"\$(cat '$m5x/state.json')\" = \"\$before5x\" ]"
check "D3. …in particular no stray comma after an opening brace" \
  "! grep -q '{,' '$m5x/state.json'"
# THE PROTECTED REPAIR STILL HAPPENS. A pre-S207 writer left a dangling comma
# behind; that file is not valid JSON either, but awk's rebuild CURES it — and
# a cure parses, so it still lands. The refusal above is only for a result that
# would still not parse.
d3f="$TMPROOT/dangling.json"
printf '{\n  "id": "m",\n  "stage": "plan",\n}\n' >"$d3f"
rc5y=0
( . "$STATE_LIB"; lcars_state_set_string "$d3f" review merged ) 2>/dev/null || rc5y=$?
check "D3. awk's dangling-comma REPAIR is untouched — it still writes" \
  "[ '$rc5y' -eq 0 ]"
check "D3. …and the repaired file parses, with the new field applied" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"review\"]==\"merged\" and d[\"id\"]==\"m\", d' '$d3f' 2>/dev/null"

# ---------------------------------------------------------------------------
# D1 (S223 fix round 3) — THE INPUT IS VALIDATED TOO, NOT JUST THE OUTPUT
# ---------------------------------------------------------------------------
# Fix round 2 (D3 above) checked that awk's RESULT parses. That let a whole
# family through: garbage APPENDED AFTER the closing brace. awk finds the last
# line that is `}` alone and rebuilds up to it, so the trailing content is
# simply DROPPED — the output parses, the check passes, and the captain's file
# comes back valid with his content silently gone, reported as "stood down" on
# exit 0. Measured on a FLAT (one-field-per-line) state.json, which is the
# shape every shipped writer emits.
#
# So the file AS IT EXISTS ON DISK must parse before anything is written —
# unless the awk pass is doing its ONE known-good repair, the pre-S207
# dangling comma, which must keep working (proved by D3 above and again here).
echo
echo "D1. garbage APPENDED after the closing brace is refused (S223 fix 3)"

d1_case() { # <name> <appended-bytes> <expect: refuse|ok>
  local name="$1" tail="$2" expect="$3" repo m before rc=0
  repo="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
  m="$(plant_mission "$repo" "$MID" verify "$XO5Z")"
  printf '%b' "$tail" >>"$m/state.json"
  before="$m/before.$$"; cp "$m/state.json" "$before"
  # the oracle: this file must really be unparseable (or, for `ok`, parseable)
  ( cd "$repo" && bash "$SCRIPT" off "$MID" >out.txt 2>err.txt ) || rc=$?
  if [ "$expect" = refuse ]; then
    check "D1. [$name] python3 agrees the INPUT does not parse" \
      "! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$before' 2>/dev/null"
    check "D1. [$name] \`lcars xo off\` EXITS NON-ZERO" "[ '$rc' -ne 0 ]"
    check "D1. [$name] …never says it stood anything down" \
      "! grep -q 'stood down' '$repo/out.txt' '$repo/err.txt'"
    check "D1. [$name] …says REFUSED and names the file" \
      "grep -q 'REFUSED' '$repo/err.txt' && grep -q \"\$(printf '%s' '$m/state.json')\" '$repo/err.txt'"
    check "D1. [$name] …and tells him it is not valid JSON" \
      "grep -qi 'not valid JSON' '$repo/err.txt'"
    check "D1. [$name] …and the file is BYTE-IDENTICAL (his content is not deleted)" \
      "cmp -s '$m/state.json' '$before'"
  else
    check "D1. [$name] \`lcars xo off\` SUCCEEDS" "[ '$rc' -eq 0 ]"
    check "D1. [$name] …and says it stood down" "grep -q 'stood down' '$repo/out.txt'"
    check "D1. [$name] …and the file is valid JSON, status stood-down" \
      "python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))[\"numberOne\"][\"status\"]==\"stood-down\"' '$m/state.json' 2>/dev/null"
  fi
}

d1_case "trailing garbage"      '  <<< not json at all >>>\n' refuse
d1_case "a trailing brace"      '}\n'                         refuse
d1_case "a second JSON doc"     '{"id": "other"}\n'           refuse
d1_case "whitespace only"       '   \n\n\t\n'                 ok

# THE PROTECTED REPAIR, once more, through the VERB and not just the library:
# a pre-S207 dangling comma is not valid JSON either, and it must still be
# repaired and written — the refusal above may not swallow it.
repo1d="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m1d="$(plant_mission "$repo1d" "$MID" verify "$XO5Z")"
python3 - "$m1d/state.json" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
# dangle the LAST field's separator, exactly as a pre-S207 writer left it
open(p, "w").write(t.replace('"githubIssue": 42\n', '"githubIssue": 42,\n'))
PY
check "D1. [dangling comma] the fixture really is invalid JSON" \
  "! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m1d/state.json' 2>/dev/null"
rc1d=0
( cd "$repo1d" && bash "$SCRIPT" off "$MID" >out.txt 2>err.txt ) || rc1d=$?
check "D1. [dangling comma] the KNOWN-GOOD repair still writes (exit 0)" "[ '$rc1d' -eq 0 ]"
check "D1. [dangling comma] …and the repaired file parses, stood down, nothing lost" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"numberOne\"][\"status\"]==\"stood-down\" and d[\"githubIssue\"]==42 and d[\"title\"]==\"Add dark mode\"' '$m1d/state.json' 2>/dev/null"

echo "SHIM invocations: $(cat "$TMPROOT/shim.log" 2>/dev/null | wc -l | tr -d ' ')"
check "Z. no model / gh was invoked" "[ ! -s '$TMPROOT/shim.log' ]"
echo
printf 'lcars xo state json: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
