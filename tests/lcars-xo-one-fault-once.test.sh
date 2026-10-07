#!/usr/bin/env bash
#
# Session 257 — STOP THE RECORDS DISAGREEING WITH EACH OTHER.
#
# Three faults of ONE SHAPE: two records of the same run exist and the one the
# captain reads is the wrong one.
#
#   FAULT 2 — EVERY BROWSER ACTION WAS REFUSED BEFORE IT RAN.
#     `xo-run.py` read the step kind from a `do` field the action schema has
#     not got: the verb is the KEY (`{"click":"#submit"}`), which is what
#     `xo-drive.js` dispatches on and what `prompts/evaluate.md` teaches. So
#     `kind` was "" for every real browser action and all twelve were refused
#     as "not a step kind the harness knows". Measured on the 2026-10-06 drive:
#     12 then 14 refusals per round, `touched: 0 control(s) clicked`, while the
#     SAME run's `walk.json` recorded `moves.clicks: 9`.
#     Second half: `xo-parts.py touched_controls()` walked the DECLARED journey
#     (`walk.steps`) only and never read the driver's own record of what it
#     clicked (`walk.actions`, `walk.moves.clicks`), so the aggregate said 0
#     while the per-step record said 9.
#
#   FAULT 3 — A URL LOSES ITS QUERY BETWEEN ROUNDS.
#     `xo.sh` re-read the per-round entry url from `launch.json`, which never
#     carried a query, and nothing recorded where the previous round ENDED —
#     so a round-2 permutation was typed against a fresh random secret.
#     `launch.sh`'s own `url_with_port` / `url_port` also dropped a query on a
#     url with no path.
#
#   FAULT 1 — ONE FAULT COUNTED SEVERAL TIMES.
#     (a) the measured side: duplicate layout observations across readings in
#         one invocation, never de-duplicated against themselves, and a key
#         that ignored `message` (the only text a published layout finding
#         has). (b) the gap side: `xo-criteria.py` resolved the `delivers` link
#         and threw it away, so two ledger rows that are one finding were
#         counted, reported and FILED twice.
#
# ZERO SPEND. No worker CLI runs anywhere in this file.
#
# Usage: bash tests/lcars-xo-one-fault-once.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XORUNPY="${LCARS_XO_RUN_PY:-$REPO_ROOT/skills/lcars-xo/xo-run.py}"
PARTS="${LCARS_XO_PARTS_PY:-$REPO_ROOT/skills/lcars-xo/xo-parts.py}"
OBSERVE="${LCARS_XO_OBSERVE_PY:-$REPO_ROOT/skills/lcars-xo/xo-observe.py}"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
CRITPY="${LCARS_XO_CRITERIA_PY:-$REPO_ROOT/skills/lcars-xo/xo-criteria.py}"
LOGSPY="${LCARS_XO_LOGS_PY:-$REPO_ROOT/skills/lcars-xo/xo-logs.py}"
XOSH="$REPO_ROOT/skills/lcars-xo/xo.sh"
LAUNCHSH="$REPO_ROOT/skills/lcars-launch/launch.sh"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 2a — a valid browser action is not refused\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
A="$TMPROOT/a"; mkdir -p "$A/m/xo"
cat >"$A/actions.json" <<'JSON'
{"actions": [
  {"navigate": "http://localhost:5173/?seed=xo-one"},
  {"click": "#submit"},
  {"type": "#guess", "text": "1234"},
  {"press": "Enter"},
  {"screenshot": "01-board"},
  {"wait": 400}
]}
JSON
"$PY" "$XORUNPY" actions --actions "$A/actions.json" --out "$A/m/xo/kept.json" \
  --mission-dir "$A/m" --cap 12 >"$A/out.txt" 2>&1
aq() { "$PY" -c "
import json,sys
d=json.load(open('$A/m/xo/kept.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "2a1. the six real browser actions are all KEPT, none refused" \
  "[ \"\$(aq 'len(d[\"steps\"])')\" = 6 ] && [ \"\$(aq 'len(d[\"refused\"])')\" = 0 ]"
for verb in navigate click type press screenshot wait; do
  check "2a2. \`$verb\` — the verb in the KEY is read as the step kind" \
    "aq '[s for s in d[\"steps\"] if \"$verb\" in s]' | grep -q '$verb'"
done

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 2b — a genuinely unknown verb is still refused, BY NAME\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
B="$TMPROOT/b"; mkdir -p "$B/m/xo"
cat >"$B/actions.json" <<'JSON'
{"actions": [
  {"frobnicate": "x"},
  {"click": "#ok"}
]}
JSON
"$PY" "$XORUNPY" actions --actions "$B/actions.json" --out "$B/m/xo/kept.json" \
  --mission-dir "$B/m" --cap 12 >"$B/out.txt" 2>&1
bq() { "$PY" -c "
import json,sys
d=json.load(open('$B/m/xo/kept.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "2b1. the unknown verb is refused and the valid one is not" \
  "[ \"\$(bq 'len(d[\"refused\"])')\" = 1 ] && [ \"\$(bq 'len(d[\"steps\"])')\" = 1 ]"
check "2b2. and the refusal NAMES what it refused (\`frobnicate\`)" \
  "bq 'd[\"refused\"][0]' | grep -q frobnicate"
check "2b3. …in the reason the captain reads, not only in a kind field" \
  "bq 'd[\"refused\"][0][\"why\"]' | grep -q frobnicate"
check "2b4. an action that is an empty object is still refused, and says so" \
  "$PY -c \"
import json,subprocess,sys
json.dump({'actions':[{}]}, open('$B/empty.json','w'))
subprocess.run([sys.executable,'$XORUNPY','actions','--actions','$B/empty.json',
                '--out','$B/kept2.json','--cap','12'],capture_output=True)
d=json.load(open('$B/kept2.json'))
r=d['refused']
sys.exit(0 if len(r)==1 and r[0].get('why') else 1)\""

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 2c — the two click records reconcile\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
C="$TMPROOT/c"; mkdir -p "$C"
# The DRIVER's own record of a round: two real clicks in `actions`, counted in
# `moves.clicks`, and an EMPTY declared journey (`steps`) — exactly the shape
# `walk.json` had on the 2026-10-06 runelock drive.
cat >"$C/walk.json" <<'JSON'
{"entry": "http://localhost:57603/",
 "steps": [],
 "actions": [{"click": "#submit"}, {"click": "#newgame"}],
 "screens": ["http://localhost:57603/"],
 "moves": {"clicks": 2, "typings": 1, "keypresses": 4, "addressJumps": 0}}
JSON
cat >"$C/build.json" <<'JSON'
{"url": "http://localhost:57603/",
 "parts": [
  {"index": 0, "id": "submit", "testid": null, "name": "Submit guess",
   "role": "button", "tag": "button", "interactive": true, "container": false,
   "box": {"x": 10, "y": 10, "w": 120, "h": 30}, "iconBox": null, "lines": 1,
   "screen": "http://localhost:57603/"},
  {"index": 1, "id": "newgame", "testid": null, "name": "New game",
   "role": "button", "tag": "button", "interactive": true, "container": false,
   "box": {"x": 137, "y": 10, "w": 100, "h": 30}, "iconBox": null, "lines": 1,
   "screen": "http://localhost:57603/"}
 ]}
JSON
printf '{"criteria": [{"id": "prd-1", "text": "it guesses", "source": "prd", "primary": true}]}\n' \
  >"$C/contract.json"
"$PY" "$PARTS" touched --walk "$C/walk.json" --build "$C/build.json" \
  --criteria "$C/contract.json" --out "$C/out.json" >"$C/say.txt" 2>&1
cq() { "$PY" -c "
import json,sys
d=json.load(open('$C/out.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "2c1. a walk whose driver record shows 2 clicks cannot report 0 clicked" \
  "[ \"\$(cq 'd[\"touchedCheck\"][\"clicked\"]')\" != 0 ]"
check "2c2. it reports the two the driver recorded" \
  "[ \"\$(cq 'd[\"touchedCheck\"][\"clicked\"]')\" = 2 ]"
check "2c3. the driver's own count is carried beside it, as a record" \
  "[ \"\$(cq 'd[\"touchedCheck\"].get(\"driverClicks\")')\" = 2 ]"
check "2c4. and the console does not say 0 control(s) clicked" \
  "! grep -q '0 control(s) clicked' \"$C/say.txt\""
check "2c5. both controls were examined, so nothing reads as unexaminable" \
  "[ \"\$(cq 'd[\"touchedCheck\"][\"examined\"]')\" = 2 ]"
# CONTROL: a walk that really clicked nothing still reports nothing.
cat >"$C/walk0.json" <<'JSON'
{"entry": "http://localhost:57603/", "steps": [], "actions": [],
 "moves": {"clicks": 0, "typings": 0, "keypresses": 0, "addressJumps": 0}}
JSON
"$PY" "$PARTS" touched --walk "$C/walk0.json" --build "$C/build.json" \
  --criteria "$C/contract.json" --out "$C/out0.json" >/dev/null 2>&1
check "2c6. CONTROL — a walk that clicked nothing still reports 0 clicked" \
  "$PY -c \"import json;print(json.load(open('$C/out0.json'))['touchedCheck']['clicked'])\" | grep -q '^0$'"
# CONTROL: the DECLARED journey's clicks still count, exactly as before.
cat >"$C/walkdecl.json" <<'JSON'
{"entry": "http://localhost:57603/",
 "steps": [{"key": "j1", "do": "click", "matched": "Submit guess",
            "status": "done", "urlBefore": "http://localhost:57603/"}],
 "actions": [],
 "moves": {"clicks": 1, "typings": 0, "keypresses": 0, "addressJumps": 0}}
JSON
"$PY" "$PARTS" touched --walk "$C/walkdecl.json" --build "$C/build.json" \
  --criteria "$C/contract.json" --out "$C/outdecl.json" >/dev/null 2>&1
check "2c7. CONTROL — a declared-journey click is still counted (no regression)" \
  "$PY -c \"import json;print(json.load(open('$C/outdecl.json'))['touchedCheck']['clicked'])\" | grep -q '^1$'"


# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 3 — a url survives a round with its query intact\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
# THE SEAM, LIFTED OUT OF xo.sh WHOLE — never a copy of it.
D="$TMPROOT/d"; mkdir -p "$D"
awk '/^json_field\(\)/,/^}$/'      "$XOSH" >"$D/seam.sh"
awk '/^xo_round_entry\(\)/,/^}$/'  "$XOSH" >>"$D/seam.sh"
check "3a0. (rig) both functions were lifted out of xo.sh whole" \
  'grep -q "xo_round_entry()" "$D/seam.sh" && grep -q "json_field()" "$D/seam.sh" && [ "$(tail -1 "$D/seam.sh")" = "}" ]'
cat >"$D/walk.json" <<'JSON'
{
  "entry": "http://localhost:57603/",
  "steps": [],
  "actions": [{"type": "#guess", "text": "1234"}],
  "screens": ["http://localhost:57603/?seed=xo-one"],
  "endedAt": "http://localhost:57603/?seed=xo-one",
  "moves": {"clicks": 0, "typings": 1, "keypresses": 0, "addressJumps": 0}
}
JSON
NEXT="$(bash -c 'source "$1"; xo_round_entry "$2" "$3"' _ "$D/seam.sh" \
          "$D/walk.json" "http://localhost:57603" 2>&1)"
check "3a1. a round that ended on ?seed=xo-one hands the NEXT round that same url" \
  '[ "$NEXT" = "http://localhost:57603/?seed=xo-one" ]'
check "3a2. …and not the bare launch url the query was lost to" \
  '[ "$NEXT" != "http://localhost:57603" ]'
# CONTROL: no end-record at all (a mission that predates this, a round with no
# page) still falls back to the launch url. No regression, no empty url.
printf '{"entry": "http://localhost:57603/", "steps": [], "actions": []}\n' >"$D/walk-old.json"
BACK="$(bash -c 'source "$1"; xo_round_entry "$2" "$3"' _ "$D/seam.sh" \
          "$D/walk-old.json" "http://localhost:57603" 2>&1)"
check "3a3. CONTROL — no end-record recorded -> the launch url, exactly as before" \
  '[ "$BACK" = "http://localhost:57603" ]'
NOFILE="$(bash -c 'source "$1"; xo_round_entry "$2" "$3"' _ "$D/seam.sh" \
          "$D/nope.json" "http://localhost:57603" 2>&1)"
check "3a4. CONTROL — no walk record at all -> the launch url" \
  '[ "$NOFILE" = "http://localhost:57603" ]'
check "3a5. xo.sh really re-reads the round entry from the walk record" \
  'grep -q "lurl=\"\$(xo_round_entry" "$XOSH"'

# ── THE DRIVER'S HALF, ON REAL HEADLESS CHROME ─────────────────────────────
# Proven end to end: a real server on a real port, a real query, a real walk
# record. Nothing about the query is faked.
DRV="${LCARS_XO_DRIVER_REAL:-$REPO_ROOT/skills/lcars-xo/xo-drive.js}"
NODE="${LCARS_NODE_BIN:-node}"
W="$TMPROOT/w"; mkdir -p "$W/site" "$W/out"
cat >"$W/site/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>seed fixture</title>
<body><h1>Runelock</h1><p id="seed">no seed</p>
<button id="submit">Submit guess</button>
<script>document.getElementById("seed").textContent =
  "seed: " + (new URLSearchParams(location.search).get("seed") || "none");</script>
HTML
( cd "$W/site" && exec "$PY" -u -m http.server 0 --bind 127.0.0.1 ) >"$W/srv.log" 2>&1 &
SRVPID=$!
PORT=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  PORT="$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$W/srv.log" | head -1)"
  [ -n "$PORT" ] && break
  "$PY" -c 'import time;time.sleep(0.25)'
done
if [ -z "$PORT" ]; then
  printf '  \033[33mSKIP\033[0m could not start a local server for the driver leg\n'
else
  "$NODE" "$DRV" --url "http://127.0.0.1:$PORT/?seed=xo-one" --out "$W/out" \
    --walk-out "$W/walk.json" --prefix r1 >"$W/drive.json" 2>"$W/drive.err"
  drc=$?
  if [ "$drc" -eq 77 ] || [ ! -s "$W/walk.json" ]; then
    printf '  \033[33mSKIP\033[0m no usable Chrome here (%s)\n' "$(head -1 "$W/drive.err" 2>/dev/null)"
  else
    wq() { "$PY" -c "
import json,sys
d=json.load(open('$W/walk.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
    check "3b1. the driver RECORDS where the round ended" \
      "wq 'bool(d.get(\"endedAt\"))' | grep -q True"
    check "3b2. and that record keeps the query the round was run with" \
      "wq 'd[\"endedAt\"]' | grep -q 'seed=xo-one'"
    check "3b3. the sticky front door is still the front door (no regression)" \
      "wq 'bool(d.get(\"entry\"))' | grep -q True"
  fi
fi
kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null

# ── AND THE DISCOVERY SIDE: launch.sh's own url arithmetic ──────────────────
L="$TMPROOT/l"; mkdir -p "$L"
awk '/^url_port\(\)/,/^}$/'      "$LAUNCHSH" >"$L/u.sh"
awk '/^url_with_port\(\)/,/^}$/' "$LAUNCHSH" >>"$L/u.sh"
check "3c0. (rig) both url helpers were lifted out of launch.sh whole" \
  'grep -q "url_with_port()" "$L/u.sh" && grep -q "url_port()" "$L/u.sh" && [ "$(tail -1 "$L/u.sh")" = "}" ]'
uw() { bash -c 'source "$1"; url_with_port "$2" "$3"' _ "$L/u.sh" "$1" "$2"; }
up() { bash -c 'source "$1"; url_port "$2"' _ "$L/u.sh" "$1"; }
check "3c1. a query on a url with NO PATH survives a port swap" \
  '[ "$(uw "http://h:5173?a=b" 6000)" = "http://h:6000?a=b" ]'
check "3c2. …and the port is still read off such a url" \
  '[ "$(up "http://h:5173?a=b")" = "5173" ]'
check "3c3. a query on a url WITH a path survives too" \
  '[ "$(uw "http://h:5173/app?a=b&c=d" 6000)" = "http://h:6000/app?a=b&c=d" ]'
check "3c4. a fragment survives, and stays after the query" \
  '[ "$(uw "http://h:5173/app?a=b#top" 6000)" = "http://h:6000/app?a=b#top" ]'
check "3c5. a fragment on a url with no path survives" \
  '[ "$(uw "http://h:5173#top" 6000)" = "http://h:6000#top" ]'
check "3c6. CONTROL — a plain url is rebuilt exactly as before" \
  '[ "$(uw "http://localhost:5173/x/y" 6000)" = "http://localhost:6000/x/y" ]'
check "3c7. CONTROL — an IPv6 literal is still kept intact" \
  '[ "$(uw "http://[::1]:5173/x" 6000)" = "http://[::1]:6000/x" ]'
check "3c8. CONTROL — url_port on a plain url is unchanged" \
  '[ "$(up "http://h:5173/x")" = "5173" ] && [ -z "$(up "http://h/x")" ]'


# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 1a — the MEASURED side: one layout fault, counted once\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
# THE REAL SHAPE, off the 2026-10-06 runelock drive. `readouts.json` holds a
# reading per screen AND more than one reading of the same screen when it
# changed under the look. The crowded "Submit guess / New game" pair is on
# every one of them, so one invocation measured it six times and `all_obs`
# took all six. The only de-dup there was keyed on `says`|`text` — and a
# PUBLISHED layout finding carries neither, only `message` — and it filtered
# `fresh` against `old` but never against ITSELF.
E="$TMPROOT/e"; mkdir -p "$E"
"$PY" - "$E/readouts.json" <<'PYEOF'
import json, sys
# Two buttons 7px apart: the crowding detector's positive case. SIX readings of
# the SAME screen (the url carries the look's seed) and ONE of the bare url —
# exactly the 1 + 6 split the live record held.
def page(url):
    def el(x, name):
        return {"index": 0, "id": None, "testid": None, "name": name,
                "role": "button", "tag": "button", "interactive": True,
                "text": name, "visible": True, "display": "inline-block",
                "box": {"x": x, "y": 40, "w": 110, "h": 30}}
    return {"url": url, "page": {"url": url, "title": "Runelock",
            "elements": [el(10, "Submit guess"), el(127, "New game")]}}
seeded = "http://localhost:57603/?seed=xo-one"
pages = [page("http://localhost:57603/")] + [page(seeded) for _ in range(6)]
json.dump({"pages": pages}, open(sys.argv[1], "w"))
PYEOF
"$PY" "$OBSERVE" "$E/readouts.json" "$E/obs.json" >"$E/say.txt" 2>&1
eq() { "$PY" -c "
import json,sys
d=json.load(open('$E/obs.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "1a1. (rig) the crowded pair really is detected" \
  "[ \"\$(eq 'len(d[\"observations\"])')\" != 0 ]"
check "1a2. seven readings of ONE crowded pair are not seven findings" \
  "[ \"\$(eq 'len(d[\"observations\"])')\" = 2 ]"
check "1a3. …and the two that survive are the two SCREENS it was seen on" \
  "[ \"\$(eq 'sorted(set(o[\"screen\"] for o in d[\"observations\"]))')\" = \"['http://localhost:57603/', 'http://localhost:57603/?seed=xo-one']\" ]"
check "1a4. the count the board reads agrees with the record it reads" \
  "[ \"\$(eq 'd[\"foundCount\"]')\" = \"\$(eq 'len(d[\"observations\"])')\" ]"
# THE INVARIANT: two findings on two DIFFERENT screens stay two.
"$PY" - "$E/two.json" <<'PYEOF'
import json, sys
def page(url, a, b):
    def el(x, name):
        return {"index": 0, "id": None, "testid": None, "name": name,
                "role": "button", "tag": "button", "interactive": True,
                "text": name, "visible": True, "display": "inline-block",
                "box": {"x": x, "y": 40, "w": 110, "h": 30}}
    return {"url": url, "page": {"url": url, "title": "t",
            "elements": [el(10, a), el(127, b)]}}
json.dump({"pages": [page("http://app/one", "ADD", "CANCEL"),
                     page("http://app/two", "SAVE", "DELETE")]},
          open(sys.argv[1], "w"))
PYEOF
"$PY" "$OBSERVE" "$E/two.json" "$E/obs2.json" >/dev/null 2>&1
check "1a5. INVARIANT — two findings on two DIFFERENT screens stay two" \
  "$PY -c \"
import json,sys
d=json.load(open('$E/obs2.json'))
sys.exit(0 if len(d['observations'])==2 and len(set(o['screen'] for o in d['observations']))==2 else 1)\""
# …and across rounds (--merge) the same screen's same finding is still one.
cp "$E/obs.json" "$E/merged.json"
"$PY" "$OBSERVE" "$E/readouts.json" "$E/merged.json" --merge >/dev/null 2>&1
check "1a6. a later round re-measuring the same screens adds nothing new" \
  "$PY -c \"
import json,sys
d=json.load(open('$E/merged.json'))
sys.exit(0 if len(d['observations'])==2 else 1)\""
check "1a7. …and the merged count does not drift away from the merged record" \
  "$PY -c \"
import json,sys
d=json.load(open('$E/merged.json'))
sys.exit(0 if d['foundCount']==len(d['observations']) else 1)\""
# THE KEY ITSELF, as a unit — because on the live record the duplicate dicts
# happened to be BYTE-IDENTICAL, so the old whole-dict fallback produced the
# same key by luck. `message` is the only text a published layout finding has,
# and it is what stops one incidental field (a crop name, an index) from
# splitting one finding into two again.
check "1a9. the key reads \`message\`: one incidental field apart is still ONE finding" \
  "$PY -c \"
import importlib.util, sys
spec = importlib.util.spec_from_file_location('obs', '$OBSERVE')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a = {'kind':'crowding','px':7,'message':'X','screen':'S','crop':'b-01'}
b = {'kind':'crowding','px':7,'message':'X','screen':'S','crop':'b-07'}
c = {'kind':'crowding','px':7,'message':'Y','screen':'S'}
d = {'kind':'crowding','px':7,'message':'X','screen':'T'}
same  = m.obs_key(a) == m.obs_key(b)
other = m.obs_key(a) != m.obs_key(c)
screen= m.obs_key(a) != m.obs_key(d)
sys.exit(0 if same and other and screen else 1)\""

# CONTROL: a merge that really brings a NEW screen's finding still grows.
"$PY" "$OBSERVE" "$E/two.json" "$E/merged.json" --merge >/dev/null 2>&1
check "1a8. CONTROL — a merge with genuinely new screens still grows the record" \
  "$PY -c \"
import json,sys
d=json.load(open('$E/merged.json'))
sys.exit(0 if len(d['observations'])==4 else 1)\""


# ── AND THE RECORDS ALREADY ON HIS MACHINE ─────────────────────────────────
# The writer is fixed above, which only helps a FRESH look. Every record he
# already has was written by the old pass, and the scorer is the one place they
# are read on the way to his board — so the same key is applied there too, and
# the board stops saying "I measured 7" about one fault on every look he has.
F="$TMPROOT/f"; mkdir -p "$F/shots"; : >"$F/shots/01.png"
"$PY" - "$F/obs.json" <<'PYEOF'
import json, sys
# The 2026-10-06 runelock record, in its own shape: SEVEN byte-identical
# crowding findings, six of them on one screen.
one = {"kind": "crowding", "px": 7,
       "elements": ["Submit guess", "New game"],
       "message": ("the Submit guess and New game buttons are crowded "
                   "together — 7 px between them")}
obs = [dict(one, screen="http://localhost:57603/")]
obs += [dict(one, screen="http://localhost:57603/?seed=xo-one") for _ in range(6)]
json.dump({"thresholds": {"gapPx": 12, "misalignPx": 2, "overflowPx": 2},
           "elementCount": 20, "unseenCount": 0, "foundCount": 10,
           "observations": obs, "notes": [],
           "screens": ["http://localhost:57603/",
                       "http://localhost:57603/?seed=xo-one"]},
          open(sys.argv[1], "w"), indent=2)
PYEOF
printf '{"criteria": [{"id": "prd-1", "text": "it guesses", "source": "prd", "primary": true}]}\n' \
  >"$F/criteria.json"
printf '{"score": "low", "summary": "Captain, two buttons are crowded.", "criteria": [{"id": "prd-1", "text": "it guesses", "status": "untested", "note": "I never got there", "evidence": "none", "impact": "high"}]}\n' \
  >"$F/worker.json"
"$PY" "$SCOREPY" "$F/worker.json" "$F/criteria.json" "$F/verdict.json" \
  "$F/obs.json" "" "" "" "" "" "" "" "" "" "$F/shots" "" "" >"$F/wire.txt" 2>&1
fq() { "$PY" -c "
import json,sys
d=json.load(open('$F/verdict.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "1a10. a record holding SEVEN copies of one finding reaches the board as TWO" \
  "[ \"\$(fq 'len(d[\"observations\"])')\" = 2 ]"
check "1a11. …one per screen it was seen on, which is the invariant" \
  "[ \"\$(fq 'len(set(o[\"screen\"] for o in d[\"observations\"]))')\" = 2 ]"
check "1a12. and the report prints it twice, not seven times" \
  "[ \"\$(grep -c 'crowded together' "$F/report.md")\" = 2 ]"

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 1b — the JOIN KEY is on disk: a delivers link is kept\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
# `xo-criteria.py` resolved the `serves` link of EVERY plan criterion and then
# threw away every one whose direction was `delivers` — `if direction !=
# "removes": continue`. So the one record that says "these two rows are the
# same requirement" never reached disk, and four ledger rows were counted,
# reported and FILED as four faults when they were two.
M="$TMPROOT/m"; mkdir -p "$M"
cat >"$M/prd.md" <<'MD'
# Rune Lock — product requirements

A small browser game.

## Acceptance criteria

1. A round can be played to a win and to a loss, and each ends as described.
2. The game follows the rules in the Rules section as written.
3. A guess that breaks a stated rule is refused with a message and costs the
   player nothing.
4. New game returns every part of the scoreboard to its starting state.
MD
cat >"$M/plan.json" <<'JSON'
{"tickets": [{"id": "t-1", "changesScreenAppearance": true,
  "acceptanceCriteria": [
   {"text": "A round can be played through to a win and to a loss, and each ends the way the Rules section describes.",
    "kind": "works", "notDrawn": "behavioural", "serves": "prd-1", "direction": "delivers"},
   {"text": "The game follows the rules printed in the Rules section as written.",
    "kind": "works", "notDrawn": "behavioural", "serves": "prd-2", "direction": "delivers"},
   {"text": "A guess that breaks a stated rule is refused with a message and costs the player nothing.",
    "kind": "works", "notDrawn": "behavioural", "serves": "prd-3", "direction": "delivers"},
   {"text": "New game returns every part of the scoreboard to its starting state.",
    "kind": "works", "notDrawn": "behavioural", "serves": "prd-4", "direction": "delivers"}
  ]}]}
JSON
"$PY" "$CRITPY" "$M" "$M/criteria.json" >"$M/crit.out" 2>&1
mq() { "$PY" -c "
import json,sys
d=json.load(open('$M/criteria.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "1b1. (rig) the contract really carries the serves/delivers pairs" \
  "mq '[c[\"serves\"] for c in d[\"criteria\"] if c.get(\"direction\")==\"delivers\"]' | grep -q prd-2"
check "1b2. a resolved \`delivers\` link is PERSISTED, not thrown away" \
  "mq 'next(c.get(\"deliversRequirement\") for c in d[\"criteria\"] if c[\"id\"]==\"t-1-ac2\")' | grep -qx prd-2"
check "1b3. every one of the four pairs is persisted" \
  "[ \"\$(mq 'len([c for c in d[\"criteria\"] if c.get(\"deliversRequirement\")])')\" = 4 ]"
check "1b4. INVARIANT — the criteria SET is unchanged: still 8 rows, 4 primary" \
  "[ \"\$(mq 'len(d[\"criteria\"])')\" = 8 ] && [ \"\$(mq 'len([c for c in d[\"criteria\"] if c.get(\"primary\")])')\" = 4 ]"
check "1b5. INVARIANT — a \`removes\` link still records a contradiction, alone" \
  "$PY -c \"
import json, subprocess, sys, os, shutil
d = '$M/rm'; shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
shutil.copy('$M/prd.md', d)
plan = json.load(open('$M/plan.json'))
plan['tickets'][0]['acceptanceCriteria'][1]['direction'] = 'removes'
json.dump(plan, open(os.path.join(d,'plan.json'),'w'))
subprocess.run([sys.executable,'$CRITPY',d,os.path.join(d,'criteria.json')],capture_output=True)
c = json.load(open(os.path.join(d,'criteria.json')))
row = next(x for x in c['criteria'] if x['id']=='t-1-ac2')
sys.exit(0 if row.get('contradictsRequirement')=='prd-2'
             and not row.get('deliversRequirement')
             and len(c['contradictions'])==1 else 1)\""

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 1c — ONE fault, counted once, with every id still readable\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
# The runelock verdict of 2026-10-06, in its own shape: FOUR gap rows that are
# TWO faults (prd-2/t-1-ac2 and prd-3/t-1-ac3), four untested rows that are
# two, and one journey row of its own. `counts` read gap 4; the board drew four
# "Didn't work" rows and `xo file-logs` filed four bugs.
G="$TMPROOT/g"; mkdir -p "$G"
"$PY" - "$M/criteria.json" "$G/worker.json" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
by = {x["id"]: x for x in c["criteria"]}
def row(cid, status, note, saw=""):
    r = {"id": cid, "text": by[cid]["text"], "status": status, "note": note,
         "kind": "works", "checkedBy": "cli", "impact": "high",
         "action": "typed 1111 into the guess box and pressed Enter",
         "reason": "I tried it; I saw %s." % (saw or note)}
    if status == "gap":
        # A judgement with no picture behind it is not a judgement (the
        # citation guard), so the fixture cites one and the shot is on disk.
        r["sawInstead"] = saw or note
        r["evidence"] = "picture"
        r["shot"] = "01-board"
    else:
        r["evidence"] = "none"
    return r
rows = [
  row("prd-1", "untested", "I never reached a finished round"),
  row("prd-2", "gap", "a guess with the same digit four times is accepted",
      "a repeated digit accepted"),
  row("prd-3", "gap", "a rule-breaking guess still costs a guess",
      "a guess spent on a refused guess"),
  row("prd-4", "untested", "I never pressed New game"),
  row("t-1-ac1", "untested", "I never reached a finished round"),
  row("t-1-ac2", "gap", "a guess with the same digit four times is accepted",
      "a repeated digit accepted"),
  row("t-1-ac3", "gap", "a rule-breaking guess still costs a guess",
      "a guess spent on a refused guess"),
  row("t-1-ac4", "untested", "I never pressed New game"),
]
json.dump({"score": "low", "criteria": rows,
           "summary": ("Captain, the game accepts a guess with the same digit "
                       "four times, and it spends a guess on a guess it "
                       "refused.")},
          open(sys.argv[2], "w"), indent=2)
PYEOF
mkdir -p "$G/shots"; : >"$G/shots/01-board.png"
"$PY" "$SCOREPY" "$G/worker.json" "$M/criteria.json" "$G/verdict.json" \
  "" "" "" "" "" "" "" "" "" "" "$G/shots" "" "" >"$G/wire.txt" 2>"$G/err.txt"
gq() { "$PY" -c "
import json,sys
d=json.load(open('$G/verdict.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "1c0. (rig) the ledger really holds 8 rows, 4 of them gaps" \
  "[ \"\$(gq 'len(d[\"criteria\"])')\" = 8 ] && [ \"\$(gq 'd[\"counts\"][\"gap\"]')\" = 4 ]"
check "1c1. the verdict RECORDS the grouping, as a record and not a parse" \
  "gq 'bool(d.get(\"faults\"))' | grep -q True"
check "1c2. the four gap rows are TWO faults" \
  "[ \"\$(gq 'len([f for f in d[\"faults\"] if f[\"status\"]==\"gap\"])')\" = 2 ]"
check "1c3. each fault names EVERY criterion that is it — nothing vanishes" \
  "gq 'sorted(sum([f[\"criteria\"] for f in d[\"faults\"] if f[\"status\"]==\"gap\"],[]))' \
     | grep -q \"\\['prd-2', 'prd-3', 't-1-ac2', 't-1-ac3'\\]\""
check "1c4. the requirement the PRD asked for is the one the fault is filed under" \
  "gq 'sorted(f[\"id\"] for f in d[\"faults\"] if f[\"status\"]==\"gap\")' | grep -q \"\\['prd-2', 'prd-3'\\]\""
check "1c5. INVARIANT — coverage is NOT lost: all 8 rows are still in the ledger" \
  "[ \"\$(gq 'len(d[\"criteria\"])')\" = 8 ]"
check "1c6. INVARIANT — counts{} is still the ROW count, so the grade cannot move" \
  "[ \"\$(gq 'd[\"counts\"][\"gap\"]')\" = 4 ]"
check "1c7. the grouped row carries the other id, readable, on the row itself" \
  "gq 'next(e.get(\"faultWith\") for e in d[\"criteria\"] if e[\"id\"]==\"prd-2\")' | grep -q t-1-ac2"
check "1c8. and the row it absorbed says which fault it belongs to" \
  "gq 'next(e.get(\"faultOf\") for e in d[\"criteria\"] if e[\"id\"]==\"t-1-ac2\")' | grep -qx prd-2"
check "1c9. the report names the pair where the captain reads his reasoning" \
  "grep -q 't-1-ac2' '$G/report.md' && grep -q 'prd-2' '$G/report.md'"

# ── THE FILTER LINE, THROUGH THE REAL board.js ─────────────────────────────
HARNESS="$REPO_ROOT/web/tests/board_xo_tab_harness.js"
NODE="${LCARS_NODE_BIN:-node}"
"$PY" - "$G/verdict.json" "$G/mi.json" <<'PYEOF'
import json, sys
v = json.load(open(sys.argv[1]))
mi = {"id": "lcars-20261006-010", "issue": 10, "stage": "verify",
      "title": "Rune Lock",
      "numberOne": {"status": "engaged", "engine": "copilot",
                    "score": v.get("score"), "headline": v.get("derivation"),
                    "report": {"score": v.get("score"), "status": "engaged",
                               "engine": "copilot", "verdict": v,
                               "logs": [], "shotsDir": "look-1",
                               "journal": []}}}
json.dump(mi, open(sys.argv[2], "w"))
PYEOF
if ! "$NODE" "$HARNESS" "$G/mi.json" >"$G/pane.json" 2>"$G/pane.err"; then
  printf '  \033[33mSKIP\033[0m the board harness would not run (%s)\n' "$(head -1 "$G/pane.err")"
else
  chips() { "$PY" -c "
import json, sys
d = json.load(open('$G/pane.json'))
out = []
def walk(n):
    if not isinstance(n, dict):
        return
    if ' xo-filter ' in (' %s ' % (n.get('cls') or n.get('_cls') or '')):
        out.append(n.get('text') or '')
    for k in n.get('children') or []:
        walk(k)
walk(d['pane'])
# ONE LABEL A LINE. Never json.dumps here: it escapes the middot the labels are
# built with, and every grep for a chip label then passes vacuously.
for lab in out:
    print(lab)"; }
  check "1c10. (rig) the real board.js drew its filter row" \
    "chips | grep -q 'All'"
  check "1c11. THE FILTER LINE COUNTS FAULTS: Didn't work reads 2, not 4" \
    "chips | grep -q \"Didn't work · 2\""
  check "1c12. …and not the row count it used to print" \
    "! chips | grep -q \"Didn't work · 4\""
  check "1c13. the other buckets are counted the same way (4 untested = 2)" \
    "chips | grep -q \"Couldn't check · 2\""
  check "1c14. and All is the sum of the buckets, so the line still adds up" \
    "chips | grep -q 'All · 4'"
  check "1c15. the absorbed criterion id is still ON the board, not deleted" \
    "$PY -c \"
import json, sys
d = json.load(open('$G/pane.json'))
txt = json.dumps(d)
sys.exit(0 if 't-1-ac2' in txt and 'prd-2' in txt else 1)\""
fi

# ── MUTATION, RUN AS A TEST: unlink the pair and the fault count doubles ────
"$PY" - "$M/criteria.json" "$G/unlinked-criteria.json" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
for x in c["criteria"]:
    x.pop("serves", None); x.pop("direction", None)
    x.pop("deliversRequirement", None)
    # …and make the texts differ too, so NOTHING joins the pair any more.
    if str(x["id"]).startswith("t-"):
        x["text"] = x["text"] + " (the ticket's own wording, deliberately different)"
json.dump(c, open(sys.argv[2], "w"), indent=2)
PYEOF
"$PY" - "$G/worker.json" "$G/unlinked-criteria.json" "$G/worker-unlinked.json" <<'PYEOF'
import json, sys
w = json.load(open(sys.argv[1]))
by = {x["id"]: x for x in json.load(open(sys.argv[2]))["criteria"]}
for r in w["criteria"]:
    r["text"] = by[r["id"]]["text"]
json.dump(w, open(sys.argv[3], "w"), indent=2)
PYEOF
"$PY" "$SCOREPY" "$G/worker-unlinked.json" "$G/unlinked-criteria.json" \
  "$G/verdict-unlinked.json" "" "" "" "" "" "" "" "" "" "" "$G/shots" "" "" \
  >"$G/wire-unlinked.txt" 2>&1
check "1c16. MUTATION CONTROL — unlink the pair and it IS two faults again" \
  "$PY -c \"
import json, sys
d = json.load(open('$G/verdict-unlinked.json'))
gaps = [e for e in d['criteria'] if e['status']=='gap']
f = [x for x in (d.get('faults') or []) if x['status']=='gap']
sys.exit(0 if len(gaps)==4 and len(f)==0 else 1)\""

# ── THE FALLBACK, AND THE LIMIT OF IT ──────────────────────────────────────
# (2) in the grouping key: identical criterion TEXT, whitespace and case only,
# for a pair the plan never linked. And the limit: two rows that DISAGREE about
# whether the thing worked are never collapsed — that disagreement is
# information, and hiding it would be the same class of fault as counting it
# twice.
"$PY" - "$G/text-criteria.json" "$G/text-worker.json" <<'PYEOF'
import json, sys
crit = {"mission": "m", "builtBeforeLaunch": True, "hasDrawing": False,
        "placeNames": [], "pictures": [], "criteria": [
  {"id": "prd-1", "text": "The score resets when New game is pressed.",
   "source": "prd", "primary": True},
  {"id": "t-9-ac1", "text": "the  SCORE   resets when New game is pressed. ",
   "source": "plan", "ticket": "t-9"},
  {"id": "prd-2", "text": "The code is never shown before the round ends.",
   "source": "prd", "primary": True},
  {"id": "t-9-ac2", "text": "The code is never shown before the round ends.",
   "source": "plan", "ticket": "t-9"},
]}
json.dump(crit, open(sys.argv[1], "w"), indent=2)
def row(cid, status):
    r = {"id": cid, "text": next(c["text"] for c in crit["criteria"] if c["id"] == cid),
         "status": status, "note": "the score stayed at 40", "kind": "works",
         "checkedBy": "cli", "impact": "high",
         "action": "pressed New game", "reason": "I tried it; I saw it stay."}
    if status == "gap":
        r["sawInstead"] = "the score stayed at 40"
        r["evidence"] = "picture"; r["shot"] = "01-board"
    else:
        r["evidence"] = "picture"; r["shot"] = "01-board"
    return r
# prd-1/t-9-ac1 agree (both gap) and must collapse.
# prd-2/t-9-ac2 DISAGREE (gap vs met) and must NOT.
json.dump({"score": "low",
           "summary": "Captain, the score does not reset when New game is pressed.",
           "criteria": [row("prd-1", "gap"), row("t-9-ac1", "gap"),
                        row("prd-2", "gap"), row("t-9-ac2", "met")]},
          open(sys.argv[2], "w"), indent=2)
PYEOF
"$PY" "$SCOREPY" "$G/text-worker.json" "$G/text-criteria.json" "$G/text-verdict.json" \
  "" "" "" "" "" "" "" "" "" "" "$G/shots" "" "" >"$G/text-wire.txt" 2>&1
tq2() { "$PY" -c "
import json,sys
d=json.load(open('$G/text-verdict.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "1c17. an UNLINKED pair with the same text (spacing and case apart) is one fault" \
  "tq2 'next(e.get(\"faultWith\") for e in d[\"criteria\"] if e[\"id\"]==\"prd-1\")' | grep -q t-9-ac1"
check "1c18. CONTROL — two rows that DISAGREE on the outcome are never collapsed" \
  "$PY -c \"
import json, sys
d = json.load(open('$G/text-verdict.json'))
by = {e['id']: e for e in d['criteria']}
sys.exit(0 if not by['prd-2'].get('faultWith') and not by['t-9-ac2'].get('faultOf') else 1)\""

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 1d — ONE bug filed per fault, not one per row\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
mkdir -p "$G/filed" "$G/filed-unlinked"
"$PY" "$LOGSPY" "$G/verdict.json" "$M/criteria.json" "$G/filed" "$G/shots" 10 \
  >"$G/filed.out" 2>"$G/filed.err"
# The same counter xo.sh reads: one `GAP` line per bug actually filed.
ngap() { grep -c '^GAP' "$1" 2>/dev/null || echo 0; }
check "1d0. (rig) the filer ran and filed something" \
  "[ \"\$(ngap "$G/filed.out")\" != 0 ]"
check "1d1. TWO bugs filed for four gap rows, not four" \
  "[ \"\$(ngap "$G/filed.out")\" = 2 ]"
check "1d2. the bugs are filed against the requirements, not the restatements" \
  "grep -q 'prd-2' "$G/filed.out" && grep -q 'prd-3' "$G/filed.out""
check "1d3. …and the row each one absorbed is NAMED in the bug it was filed as" \
  "grep -rq 't-1-ac2' "$G/filed"/*.md"
"$PY" "$LOGSPY" "$G/verdict-unlinked.json" "$G/unlinked-criteria.json" \
  "$G/filed-unlinked" "$G/shots" 10 >"$G/filed-unlinked.out" 2>&1
check "1d4. MUTATION CONTROL — with nothing joining them it files four again" \
  "[ \"\$(ngap "$G/filed-unlinked.out")\" = 4 ]"

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 2c — the argv fence judges the verb the gate RESOLVED\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
# THE DEFECT (fix round 1, measured on this very file's own subject). Fault 2
# taught `action_kind` to read the verb off the step's KEY, because the action
# schema is `{"click":"#sel"}` and not `{"do":"click"}`. But the argv fence
# behind the request gate still asked `step["do"] == "run"`, so a REACH verb
# written in key form walked straight past it:
#
#   {"do":  "run", "argv": ["sh","-c","echo PWNED"]}  → refused   (correct)
#   {"run": "x",   "argv": ["sh","-c","echo PWNED"]}  → KEPT      (wrong)
#
# Nothing ever executed — `cmd_journey` refuses a key-form step outright — so
# this was a FALSE RECORD rather than a breach, and a false record is exactly
# the fault class this session exists to close: the kept/refused ledger and the
# console said a shell request had been GRANTED, the refusal stopped naming the
# shell, and the 12-action cap counted the step as spent.
#
# One verb is one verb however it was written, so the fence is applied to the
# kind `action_kind` resolved — and `do` behaves exactly as it always did.
FN="$TMPROOT/fence"; mkdir -p "$FN/m/xo"
cat >"$FN/actions.json" <<'JSON'
{"actions": [
  {"run": "shell-key-form", "argv": ["sh", "-c", "echo PWNED"], "cwd": "<worktree>"},
  {"workflow": "shell-key-form", "argv": ["bash", "-c", "echo PWNED"], "cwd": "<worktree>"},
  {"run": "inline-code", "argv": ["python3", "-c", "print(1)"], "cwd": "<worktree>"},
  {"run": "absolute", "argv": ["/bin/ls", "/etc"], "cwd": "<worktree>"},
  {"run": "escaped-cwd", "argv": ["python3", "-m", "relay"], "cwd": "/etc"},
  {"do": "run", "argv": ["sh", "-c", "echo PWNED"], "cwd": "<worktree>"},
  {"run": "honest", "argv": ["python3", "-m", "relay", "--help"], "cwd": "<worktree>"},
  {"click": "#submit"},
  {"navigate": "http://localhost:5173/"},
  {"type": "#guess", "text": "1234"},
  {"press": "Enter"}
]}
JSON
"$PY" "$XORUNPY" actions --actions "$FN/actions.json" --out "$FN/m/xo/kept.json" \
  --mission-dir "$FN/m" --cap 12 >"$FN/out.txt" 2>&1
nq() { "$PY" -c "
import json,sys
d=json.load(open('$FN/m/xo/kept.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
# The refusals, joined, so one grep can ask whether the shell was NAMED.
nwhy() { "$PY" -c "
import json
d=json.load(open('$FN/m/xo/kept.json'))
print(' || '.join(str(r.get('why','')) for r in d.get('refused') or []))"; }
check "2c0. (rig) the gate ran and wrote its ledger" \
  "[ -s '$FN/m/xo/kept.json' ]"
check "2c1. a key-form reach step asking for a shell is REFUSED" \
  "[ \"\$(nq 'len([s for s in d[\"reachSteps\"] if s.get(\"argv\",[None])[0] in (\"sh\",\"bash\")])')\" = 0 ]"
check "2c2. …and ALL THREE shell requests are named as shells, not just the do one" \
  "[ \"\$(nq 'len([r for r in d[\"refused\"] if \"asks for a shell\" in r.get(\"why\",\"\")])')\" = 3 ]"
check "2c3. a key-form WORKFLOW step asking for a shell is refused too" \
  "[ \"\$(nq 'len([s for s in d[\"reachSteps\"] if \"workflow\" in s])')\" = 0 ]"
check "2c4. key-form inline code (a shell in another coat) is refused" \
  "nwhy | grep -q 'inline code'"
check "2c5. a key-form absolute path in the argv is refused" \
  "nwhy | grep -q 'absolute path /bin/ls'"
check "2c6. CONTROL — a cwd outside the worktree was always refused, and still is" \
  "nwhy | grep -q 'cwd /etc'"
check "2c7. CONTROL — the DECLARED do form is refused exactly as it always was" \
  "[ \"\$(nq 'len([s for s in d[\"reachSteps\"] if s.get(\"do\")])')\" = 0 ]"
check "2c8. six steps refused, and the console says so" \
  "[ \"\$(nq 'len(d[\"refused\"])')\" = 6 ] && grep -q '6 refused' '$FN/out.txt'"
check "2c9. NOT A BLANKET REFUSAL — the honest key-form reach step is KEPT" \
  "[ \"\$(nq 'len(d[\"reachSteps\"])')\" = 1 ] && \
   [ \"\$(nq 'd[\"reachSteps\"][0][\"run\"]')\" = honest ]"
check "2c10. …and all four valid browser steps are still kept" \
  "[ \"\$(nq 'len(d[\"steps\"])')\" = 4 ]"
check "2c11. the cap is not spent on a step that was refused" \
  "grep -q '11 asked, 5 kept' '$FN/out.txt'"

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 1a (fix round 1) — a de-duplication that cannot run SAYS SO\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
# `load_observations` loads `obs_key` out of `xo-observe.py` so there is ONE key
# and not two, and on any exception it set `_key = None` and carried every
# finding through verbatim — i.e. the old inflated board came back with no
# signal in the verdict, in the report, or on the wire. A broken install would
# silently restore the very board the captain complained about, and nothing he
# reads would have said so.
#
# The BEHAVIOUR is right and is kept: a de-dup is never a reason to lose a
# verdict. What was missing is the record. So the fallback now writes the one
# sentence that says de-duplication did not run, in the same `notes` the file
# already uses for everything it could not do — which reaches `ledgerNotes`,
# the report's "How I put this together", and `NOTE` on the wire.
D="$TMPROOT/dedup"; mkdir -p "$D/lonely" "$D/shots" "$D/b" "$D/w"; : >"$D/shots/01.png"
# A COPY OF THE REAL SCORER WITH NOTHING BESIDE IT — exactly a broken install.
cp "$SCOREPY" "$D/lonely/xo-score.py"
"$PY" - "$D/obs.json" <<'PYEOF'
import json, sys
one = {"kind": "crowding", "px": 7,
       "elements": ["Submit guess", "New game"],
       "message": ("the Submit guess and New game buttons are crowded "
                   "together — 7 px between them")}
obs = [dict(one, screen="http://localhost:57603/")]
obs += [dict(one, screen="http://localhost:57603/?seed=xo-one") for _ in range(6)]
json.dump({"thresholds": {"gapPx": 12, "misalignPx": 2, "overflowPx": 2},
           "elementCount": 20, "unseenCount": 0, "foundCount": 10,
           "observations": obs, "notes": [],
           "screens": ["http://localhost:57603/",
                       "http://localhost:57603/?seed=xo-one"]},
          open(sys.argv[1], "w"), indent=2)
PYEOF
printf '{"criteria": [{"id": "prd-1", "text": "it guesses", "source": "prd", "primary": true}]}\n' \
  >"$D/criteria.json"
printf '{"score": "low", "summary": "Captain, two buttons are crowded.", "criteria": [{"id": "prd-1", "text": "it guesses", "status": "untested", "note": "I never got there", "evidence": "none", "impact": "high"}]}\n' \
  >"$D/worker.json"
# The BROKEN install: the scorer alone in a directory, so the key cannot load.
"$PY" "$D/lonely/xo-score.py" "$D/worker.json" "$D/criteria.json" "$D/b/verdict.json" \
  "$D/obs.json" "" "" "" "" "" "" "" "" "" "$D/shots" "" "" >"$D/broken-wire.txt" 2>&1
# The SAME inputs through the real file, which can load its key.
"$PY" "$SCOREPY" "$D/worker.json" "$D/criteria.json" "$D/w/verdict.json" \
  "$D/obs.json" "" "" "" "" "" "" "" "" "" "$D/shots" "" "" >"$D/whole-wire.txt" 2>&1
dq() { "$PY" -c "
import json,sys
d=json.load(open(sys.argv[2]))
print(eval(sys.argv[1],{'d':d}))" "$1" "$2"; }
check "1a13. (rig) the lonely copy really cannot load the key, and still scored" \
  "[ -s '$D/b/verdict.json' ] && grep -q '^SCORE' '$D/broken-wire.txt'"
check "1a14. BEHAVIOUR KEPT — no verdict is lost over a de-dup: all seven carry through" \
  "[ \"\$(dq 'len(d[\"observations\"])' '$D/b/verdict.json')\" = 7 ]"
check "1a15. THE FALLBACK IS LOUD — the verdict RECORDS that de-duplication did not run" \
  "dq 'd.get(\"ledgerNotes\") or []' '$D/b/verdict.json' | grep -qi 'de-duplicat'" 
check "1a16. …and the sentence names the key it could not load, so it is actionable" \
  "dq 'd.get(\"ledgerNotes\") or []' '$D/b/verdict.json' | grep -q 'xo-observe.py'"
check "1a17. …and it reaches the wire xo.sh journals, not only the file" \
  "grep -i '^NOTE' '$D/broken-wire.txt' | grep -qi 'de-duplicat'"
check "1a18. …and the report the captain reads says it too" \
  "grep -qi 'de-duplicat' '$D/b/report.md'"
check "1a19. CONTROL — a WHOLE install de-dups to two and says nothing about it" \
  "[ \"\$(dq 'len(d[\"observations\"])' '$D/w/verdict.json')\" = 2 ] && \
   ! dq 'd.get(\"ledgerNotes\") or []' '$D/w/verdict.json' | grep -qi 'de-duplicat'"

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 1b (fix round 1) — the captain OLD boards cure too\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
# THE LIMITATION A FRESH TESTER FOUND. `deliversRequirement` is written into a
# review's criteria file when the review is SET UP, so re-opening a review
# recorded BEFORE this session only grouped pairs whose wording was word-for-
# word identical. Measured on last night's five looks: 6→5, 3→2, 6→4, 4→3, 6→4
# instead of 6→3, 3→2, 6→3, 4→2, 6→3.
#
# AND THE RECORD WAS ALREADY THERE. Every one of those five `criteria.json`
# files already carries `{"serves": "prd-2", "direction": "delivers"}` on four
# rows — it is only the pre-resolved field that is absent. So the grouping reads
# the declaration that is on disk, exactly as `xo-criteria.py` resolves it, and
# the captain's existing boards cure without a fresh review. NOTHING is
# re-derived from a PRD and the criteria SET does not change.
O="$TMPROOT/old"; mkdir -p "$O/shots"; cp "$G/shots/01-board.png" "$O/shots/" 2>/dev/null \
  || : >"$O/shots/01-board.png"
# THE OLD SHAPE, MADE FROM THE NEW ONE: the pre-resolved field removed, the raw
# `serves`/`direction` declaration left exactly as a pre-S257 review wrote it.
"$PY" - "$M/criteria.json" "$O/criteria.json" "$O/no-serves.json" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
old = json.loads(json.dumps(c))
for r in old["criteria"]:
    r.pop("deliversRequirement", None)
json.dump(old, open(sys.argv[2], "w"), indent=2)
# The mutation control: the same old shape with the `serves` pointer gone, so
# there is nothing on disk to read and only identical text could join a pair.
blind = json.loads(json.dumps(old))
for r in blind["criteria"]:
    r.pop("serves", None)
json.dump(blind, open(sys.argv[3], "w"), indent=2)
PYEOF
"$PY" "$SCOREPY" "$G/worker.json" "$O/criteria.json" "$O/verdict.json" \
  "" "" "" "" "" "" "" "" "" "" "$O/shots" "" "" >"$O/wire.txt" 2>&1
oq() { "$PY" -c "
import json,sys
d=json.load(open('$O/verdict.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "1b6. (rig) the old-shape contract declares serves/delivers and NOT the new field" \
  "[ \"\$(\"$PY\" -c \"
import json
d=json.load(open('$O/criteria.json'))
print(len([c for c in d['criteria'] if c.get('direction')=='delivers']))\")\" = 4 ] && \
   [ \"\$(\"$PY\" -c \"
import json
d=json.load(open('$O/criteria.json'))
print(len([c for c in d['criteria'] if c.get('deliversRequirement')]))\")\" = 0 ]"
check "1b7. (rig) the two halves of a pair are NOT word-for-word the same sentence" \
  "$PY -c \"
import json, sys
d = json.load(open('$O/criteria.json'))
by = {c['id']: c['text'] for c in d['criteria']}
sys.exit(0 if by['prd-2'] != by['t-1-ac2'] else 1)\""
check "1b8. a review recorded BEFORE this change still groups its pair" \
  "oq 'next(e.get(\"faultWith\") for e in d[\"criteria\"] if e[\"id\"]==\"prd-2\")' | grep -q t-1-ac2"
check "1b9. …and the absorbed row says which fault it belongs to" \
  "oq 'next(e.get(\"faultOf\") for e in d[\"criteria\"] if e[\"id\"]==\"t-1-ac2\")' | grep -qx prd-2"
check "1b10. the four gap rows of an OLD review are TWO faults, not four" \
  "[ \"\$(oq 'len([f for f in d.get(\"faults\") or [] if f[\"status\"]==\"gap\"])')\" = 2 ]"
check "1b11. INVARIANT — no criterion is lost: all 8 rows are still in the ledger" \
  "[ \"\$(oq 'len(d[\"criteria\"])')\" = 8 ]"
check "1b12. INVARIANT — counts{} is still the ROW count, so no grade can move" \
  "[ \"\$(oq 'd[\"counts\"][\"gap\"]')\" = 4 ]"
mkdir -p "$O/filed" "$O/filed-blind"
"$PY" "$LOGSPY" "$O/verdict.json" "$O/criteria.json" "$O/filed" "$O/shots" 10 \
  >"$O/filed.out" 2>"$O/filed.err"
check "1b13. and an OLD review files TWO bugs for its four gap rows" \
  "[ \"\$(ngap "$O/filed.out")\" = 2 ]"
# MUTATION: ignore the `serves` link. Nothing else changes.
"$PY" "$SCOREPY" "$G/worker.json" "$O/no-serves.json" "$O/blind-verdict.json" \
  "" "" "" "" "" "" "" "" "" "" "$O/shots" "" "" >"$O/blind-wire.txt" 2>&1
# The discriminating pair is prd-2/t-1-ac2: the plan restated it in different
# words ("the rules printed in the Rules section"), so identical text cannot
# join it and ONLY the declaration on disk can. The other two pairs happen to be
# word-for-word and still join on text, which is the pre-existing rule.
check "1b14. MUTATION CONTROL — with the serves pointer gone the re-worded pair splits again" \
  "$PY -c \"
import json, sys
d = json.load(open('$O/blind-verdict.json'))
by = {e['id']: e for e in d['criteria']}
sys.exit(0 if not by['prd-2'].get('faultWith') and not by['t-1-ac2'].get('faultOf')
             and len([f for f in d.get('faults') or [] if f['status'] == 'gap']) == 1
             else 1)\""

# ═══════════════════════════════════════════════════════════════════════════
printf '\n\033[1mFAULT 1c (fix round 2) — only a gap is called a fault\033[0m\n'
# ═══════════════════════════════════════════════════════════════════════════
PW="$TMPROOT/pair-words"; mkdir -p "$PW"
"$PY" - "$G/worker.json" "$PW/worker.json" <<'PYEOF'
import json, sys
w = json.load(open(sys.argv[1]))
for row in w["criteria"]:
    if row["id"] in ("prd-1", "t-1-ac1"):
        row["status"] = "met"
        row["evidence"] = "picture"
        row["shot"] = "01-board"
    elif row["id"] in ("prd-3", "t-1-ac3"):
        row["status"] = "untested"
        row["evidence"] = "none"
        row.pop("sawInstead", None)
        row.pop("shot", None)
json.dump(w, open(sys.argv[2], "w"), indent=2)
PYEOF
"$PY" "$SCOREPY" "$PW/worker.json" "$M/criteria.json" "$PW/verdict.json" \
  "" "" "" "" "" "" "" "" "" "" "$G/shots" "" "" >"$PW/wire.txt" 2>&1
check "1c19. a paired GAP row still says one fault" \
  "grep -F '*(prd-2)*' '$PW/report.md' | grep -q 'one fault'"
check "1c20. a paired MET row names its pair without calling it a fault" \
  "grep -F '*(prd-1)*' '$PW/report.md' | grep -q 't-1-ac1' && \
   ! grep -F '*(prd-1)*' '$PW/report.md' | grep -q 'one fault'"
check "1c21. a paired UNTESTED faultOf row names its pair without calling it a fault" \
  "grep -F '*(t-1-ac3)*' '$PW/report.md' | grep -q 'prd-3' && \
   ! grep -F '*(t-1-ac3)*' '$PW/report.md' | grep -q 'one fault'"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
