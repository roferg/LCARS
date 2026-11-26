#!/usr/bin/env bash
# Product-path ports of .daywatch/reference/usage.test.sh, groups 1, 2, 6-10,
# 19, 25-26, 32-34 and 36-37. No network, Keychain or worker calls.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${CHAIN_USAGE_SCRIPT:-$ROOT/skills/lcars-usage/usage.sh}"
ECH="${LCARS_ECH_SCRIPT:-$ROOT/skills/lcars-eeh/ech.sh}"
SELECT="${LCARS_USAGE_CASE:-all}"
case "$SELECT" in
  all|read|gate|destination|bearer|pair|unknown|future|uninstalled|mounts) ;;
  *) printf 'unknown usage test case: %s\n' "$SELECT" >&2; exit 64 ;;
esac
export TZ="America/Los_Angeles"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
NOW=1789156800
FAKE_TOKEN="FAKE-TOKEN-not-a-real-credential"
pass=0
fail=0

check() {
  local label="$1"; shift
  if "$@"; then
    printf 'PASS %s\n' "$label"; pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$label"; fail=$((fail + 1))
  fi
}
selected() { [ "$SELECT" = all ] || [ "$SELECT" = "$1" ]; }
cachedir() { mktemp -d "$TMPROOT/cache.XXXXXX"; }
iso_at() {
  python3 - "$NOW" "$1" <<'PY'
import datetime, sys
print(datetime.datetime.fromtimestamp(
    int(sys.argv[1]) + 60 * float(sys.argv[2]), datetime.timezone.utc).isoformat())
PY
}
body_both() {
  local f; f="$(mktemp "$TMPROOT/body.XXXXXX")"
  cat >"$f" <<JSON
{"five_hour":{"utilization":$1,"resets_at":"$(iso_at "$2")"},
 "seven_day":{"utilization":$3,"resets_at":"$(iso_at 4080)"},
 "a_key_nobody_has_seen_before":{"nested":{"surprise":true}}}
JSON
  echo "$f"
}
keychain() {
  local f; f="$(mktemp "$TMPROOT/kc.XXXXXX")"
  python3 - "$f" "$NOW" "$FAKE_TOKEN" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"claudeAiOauth": {
        "accessToken": sys.argv[3], "refreshToken": "FAKE-REFRESH",
        "expiresAt": (int(sys.argv[2]) + 18000) * 1000}}, f)
PY
  echo "$f"
}
curl_stub() {
  local f; f="$(mktemp "$TMPROOT/curl.XXXXXX")"
  cat >"$f" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$3"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && cat "$2" >"\$out"
prev=""
for a in "\$@"; do
  hf=""
  case "\$prev" in
    --config|-K) hf="\$a" ;;
    -H) case "\$a" in @?*) hf="\${a#@}" ;; esac ;;
  esac
  if [ -n "\$hf" ] && [ -f "\$hf" ]; then
    printf '%s\n' "\$hf" >>"$3.cfgpath"
    python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "\$hf" >>"$3.cfgmode"
    python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(os.path.dirname(sys.argv[1])).st_mode))[2:])' "\$hf" >>"$3.dirmode"
    cat "\$hf" >>"$3.cfg"
  fi
  prev="\$a"
done
printf '%s' "$1"
EOF
  chmod +x "$f"
  echo "$f"
}
run_chain() {
  local kc="$1" curlbin="$2" cache="$3"; shift 3
  local kcmd="echo {}"
  [ "$kc" = - ] || kcmd="cat '$kc'"
  [ "$curlbin" != - ] || curlbin=/usr/bin/false
  env -u CLAUDE_CODE_OAUTH_TOKEN \
    CHAIN_KEYCHAIN_CMD="$kcmd" CHAIN_CURL_BIN="$curlbin" CHAIN_NOW="$NOW" \
    CHAIN_CACHE_DIR="$cache" CHAIN_CONFIG="${CHAIN_CONFIG:-}" \
    CHAIN_USAGE_URL="${TEST_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}" \
    bash "$SCRIPT" "$@" </dev/null
}
json_is() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert eval(sys.argv[2]), d
PY
}

if selected read; then
  kc="$(keychain)"; log="$TMPROOT/read.log"; cache="$(cachedir)"
  stub="$(curl_stub 200 "$(body_both 42 82 31)" "$log")"
  run_chain "$kc" "$stub" "$cache" read --json >"$TMPROOT/read.json" 2>"$TMPROOT/read.err"
  rc=$?
  check "1a. product read --json exits 0" test "$rc" -eq 0
  check "1b. normalised percentages and epoch resets (42/31, 1789161720/1789401600)" \
    json_is "$TMPROOT/read.json" \
    'd["source"] == "endpoint" and d["readAt"] == 1789156800 and d["fiveHour"] == {"pct":42,"resetsAt":1789161720} and d["weekly"] == {"pct":31,"resetsAt":1789401600}'
  env -u CHAIN_CONFIG CHAIN_KEYCHAIN_CMD=true CHAIN_CURL_BIN=/usr/bin/false \
    CHAIN_CACHE_DIR="$(cachedir)" bash "$SCRIPT" config >"$TMPROOT/config" 2>&1
  check "1c. product reads its shipped usage.json (weekly ASK at 95%)" \
    grep -q 'weekly limit is >= 95%' "$TMPROOT/config"
fi

if selected gate; then
  # Reference group 6 uses the original 70% weekly threshold; the shipped
  # captain's config now says 95%, which group 1 checks separately.
  printf '%s\n' '{"thresholds":{"fiveHourGo":70,"fiveHourGrace":80,"graceMinutes":45,"weeklyAsk":70}}' \
    >"$TMPROOT/thresholds.json"
  gate_case() {
    local stub
    stub="$(curl_stub 200 "$(body_both "$1" "$2" "$3")" "$TMPROOT/gate.$RANDOM.log")"
    CHAIN_CONFIG="$TMPROOT/thresholds.json" \
      run_chain "$(keychain)" "$stub" "$(cachedir)" gate "${@:4}"
  }
  for row in '65 200 10 GO 0' '75 60 10 HOLD 2' '75 30 10 GO 0' \
             '81 10 10 HOLD 2' '40 200 70 ASK 3' '85 200 70 HOLD 2' \
             '70 200 69 GO 0' '80 44 69 GO 0' '80 46 69 HOLD 2'; do
    read -r five minutes weekly verdict code <<<"$row"
    gate_case "$five" "$minutes" "$weekly" >"$TMPROOT/gate" 2>&1; rc=$?
    check "2. $five%/$weekly%, reset ${minutes}m -> $verdict exit $code" \
      test "$rc" -eq "$code"
    check "2. prose verdict is $verdict" grep -q "^$verdict " "$TMPROOT/gate"
  done
  for row in '65 200 10 GO 0' '71 200 10 HOLD 2' '40 200 72 ASK 3'; do
    read -r five minutes weekly verdict code <<<"$row"
    gate_case "$five" "$minutes" "$weekly" --json >"$TMPROOT/gate.json" 2>"$TMPROOT/gate.err"; rc=$?
    check "2. gate --json $verdict agrees with exit $code" test "$rc" -eq "$code"
    check "2. JSON verdict/exitCode are $verdict/$code" \
      json_is "$TMPROOT/gate.json" "d['verdict'] == '$verdict' and d['exitCode'] == $code"
  done
  run_chain - - "$(cachedir)" gate --json >"$TMPROOT/unknown.json" 2>&1; rc=$?
  check "2. missing credentials -> UNKNOWN exit 4" test "$rc" -eq 4
  check "2. UNKNOWN JSON contains null numbers, never invented zeroes" \
    json_is "$TMPROOT/unknown.json" \
    'd["verdict"] == "UNKNOWN" and d["exitCode"] == 4 and d["fiveHour"]["pct"] is None and d["weekly"]["pct"] is None'
  run_chain - - "$(cachedir)" gate --bogus-flag >"$TMPROOT/bogus" 2>&1; rc=$?
  check "2. invalid argument -> usage exit 64" test "$rc" -eq 64
fi

if selected destination; then
  kc="$(keychain)"; log="$TMPROOT/url.log"
  stub="$(curl_stub 200 "$(body_both 3 60 3)" "$log")"
  for url in 'http://127.0.0.1:9/x' 'https://elsewhere/x' \
             'https://api.anthropic.com@elsewhere/x' \
             'https://api.anthropic.com.elsewhere/x' \
             'api.anthropic.com/api/oauth/usage' \
             $'https://api.anthropic.com/x\nhttps://127.0.0.1/y' \
             $'https://api.anthropic.com/x\r\nHost: elsewhere' \
             $'https://api.anthropic.com/x\ty' \
             'https://api.anthropic.com/x y' $'https://api.anthropic.com/x\vy'; do
    for verb in read gate; do
      TEST_USAGE_URL="$url" run_chain "$kc" "$stub" "$(cachedir)" "$verb" \
        >"$TMPROOT/url.out" 2>&1; rc=$?
      printf -v shown '%q' "$url"
      check "3. $verb refuses $shown before curl (exit 64)" test "$rc" -eq 64
      check "3. refusal names https://api.anthropic.com" \
        grep -q 'https://api.anthropic.com' "$TMPROOT/url.out"
      check "3. refused destination receives no request or credential file" \
        test ! -e "$log"
      check "3. no credential header reached the stub" test ! -e "$log.cfg"
    done
  done
  TEST_USAGE_URL='' run_chain "$kc" "$stub" "$(cachedir)" gate >"$TMPROOT/url.good" 2>&1; rc=$?
  check "3. CONTROL empty URL uses the allowed default and GO/0" test "$rc" -eq 0
  check "3. CONTROL allowed host actually reaches curl" \
    grep -q 'https://api.anthropic.com/api/oauth/usage' "$log"
fi

if selected bearer; then
  for status in 200 500; do
    kc="$(keychain)"; log="$TMPROOT/bearer.$status.log"; cache="$(cachedir)"
    stub="$(curl_stub "$status" "$(body_both 6 60 6)" "$log")"
    run_chain "$kc" "$stub" "$cache" read --json >"$TMPROOT/bearer.out" 2>&1; rc=$?
    expected=0; [ "$status" = 200 ] || expected=4
    check "4. HTTP $status read exits $expected" test "$rc" -eq "$expected"
    check "4. HTTP $status curl actually ran" test -s "$log"
    check "4. HTTP $status bearer absent from recorded curl argv" \
      bash -c '! grep -qE "$1|Bearer" "$2"' -- "$FAKE_TOKEN" "$log"
    check "4. HTTP $status exact Authorization header is sent off argv" \
      grep -qx "Authorization: Bearer $FAKE_TOKEN" "$log.cfg"
    check "4. HTTP $status credential file is mode 0600" grep -qx 600 "$log.cfgmode"
    check "4. HTTP $status credential directory is mode 0700" grep -qx 700 "$log.dirmode"
    check "4. HTTP $status exactly one credential file per request" \
      test "$(wc -l <"$log.cfgpath" 2>/dev/null | tr -d ' ')" = 1
    path="$(head -n 1 "$log.cfgpath" 2>/dev/null)"
    check "4. HTTP $status recorded credential path is nonempty" test -n "$path"
    check "4. HTTP $status credential file is deleted on return" test ! -e "$path"
    check "4. HTTP $status token absent from output and cache" \
      bash -c '! grep -rq "$1" "$2" "$3"' -- "$FAKE_TOKEN" "$TMPROOT/bearer.out" "$cache"
  done
fi

if selected pair; then
  log="$TMPROOT/pair.log"
  stub="$(curl_stub 200 "$(body_both 99 200 99)" "$log")"
  kc="$(keychain)"
  for verb in read gate; do
    for half in --five-hour --weekly --five-hour-resets-in; do
      run_chain "$kc" "$stub" "$(cachedir)" "$verb" "$half" 10 \
        >"$TMPROOT/pair.out" 2>&1; rc=$?
      check "5. $verb $half alone exits 64" test "$rc" -eq 64
      case "$half" in
        --five-hour) missing=--weekly ;;
        *) missing=--five-hour ;;
      esac
      check "5. $verb $half names missing $missing" grep -q -- "$missing.*missing" "$TMPROOT/pair.out"
      if [ "$half" = --five-hour-resets-in ]; then
        check "5. resets-in alone names both missing halves" grep -q -- '--weekly.*missing' "$TMPROOT/pair.out"
      fi
      check "5. incomplete override receives no verdict" \
        bash -c '! grep -qE "GO|HOLD|ASK|UNKNOWN" "$1"' -- "$TMPROOT/pair.out"
    done
  done
  check "5. incomplete override never calls curl" test ! -e "$log"
  for minutes in 20 90; do
    run_chain "$kc" "$stub" "$(cachedir)" gate --five-hour 78 --weekly 10 \
      --five-hour-resets-in "$minutes" >"$TMPROOT/pair.good" 2>&1; rc=$?
    code=0; [ "$minutes" = 20 ] || code=2
    check "5. complete pair with ${minutes}m reset preserves grace (exit $code)" test "$rc" -eq "$code"
  done
  check "5. complete overrides also make no request" test ! -e "$log"
fi

if selected unknown; then
  for weekly in '{"utilization":"95"}' '{"utilization":null}' \
                '{"utilization":true}' '95' '{}' '{"pct":95}' 'null'; do
    body="$TMPROOT/weekly.json"
    printf '{"five_hour":{"utilization":5},"seven_day":%s}\n' "$weekly" >"$body"
    stub="$(curl_stub 200 "$body" "$TMPROOT/weekly.$RANDOM.log")"
    run_chain "$(keychain)" "$stub" "$(cachedir)" gate >"$TMPROOT/weekly.out" 2>&1; rc=$?
    check "6. unreadable weekly $weekly -> UNKNOWN exit 4" test "$rc" -eq 4
    check "6. unreadable weekly is named, never GO or a traceback" \
      bash -c 'grep -q "^UNKNOWN" "$1" && grep -qi weekly "$1" && ! grep -qiE "GO|traceback" "$1"' \
      -- "$TMPROOT/weekly.out"
  done
  for source in cache statusline; do
    cache="$(cachedir)"
    if [ "$source" = cache ]; then
      printf '{"source":"endpoint","readAt":%s,"fiveHour":{"pct":5},"weekly":{"pct":"95"},"note":""}\n' \
        "$NOW" >"$cache/usage.json"
    else
      printf '%s\n' '{"rate_limits":{"five_hour":{"used_percentage":5},"seven_day":{"used_percentage":"95"}}}' \
        >"$cache/statusline.json"
    fi
    run_chain - - "$cache" gate --json >"$TMPROOT/weekly.json.out" 2>&1; rc=$?
    check "6. unreadable weekly from $source -> UNKNOWN exit 4" test "$rc" -eq 4
    check "6. $source JSON refuses with UNKNOWN, not GO" \
      json_is "$TMPROOT/weekly.json.out" 'd["verdict"] == "UNKNOWN" and d["exitCode"] == 4'
  done
  for row in '69 GO 0' '96 ASK 3'; do
    read -r weekly verdict code <<<"$row"
    printf '{"five_hour":null,"seven_day":{"utilization":%s}}\n' "$weekly" >"$TMPROOT/no-five.json"
    stub="$(curl_stub 200 "$TMPROOT/no-five.json" "$TMPROOT/nofive.$RANDOM.log")"
    run_chain "$(keychain)" "$stub" "$(cachedir)" gate --json >"$TMPROOT/nofive.out" 2>&1; rc=$?
    check "6. CONTROL no 5-hour window, readable weekly $weekly -> $verdict exit $code" test "$rc" -eq "$code"
    check "6. no-window JSON keeps fiveHour.pct null without inventing zero" \
      json_is "$TMPROOT/nofive.out" "d['verdict'] == '$verdict' and d['fiveHour']['pct'] is None"
  done
fi

if selected future; then
  seed_cache() {
    printf '{"source":"endpoint","readAt":%s,"fiveHour":{"pct":5,"resetsAt":%s},"weekly":{"pct":10,"resetsAt":%s},"note":""}\n' \
      "$2" "$((NOW + 12000))" "$((NOW + 244800))" >"$1/usage.json"
  }
  cache="$(cachedir)"; seed_cache "$cache" "$((NOW + 36000))"
  run_chain - - "$cache" gate >"$TMPROOT/future.none" 2>&1; rc=$?
  check "7. future cache with no live read -> UNKNOWN exit 4, never frozen GO" test "$rc" -eq 4
  check "7. future cache is not reported as GO" grep -q '^UNKNOWN' "$TMPROOT/future.none"
  cache="$(cachedir)"; seed_cache "$cache" "$((NOW + 36000))"
  log="$TMPROOT/future.log"; stub="$(curl_stub 200 "$(body_both 95 200 10)" "$log")"
  run_chain "$(keychain)" "$stub" "$cache" gate >"$TMPROOT/future.live" 2>&1; rc=$?
  check "7. future cache forces one endpoint call" test "$(wc -l <"$log" 2>/dev/null | tr -d ' ')" = 1
  check "7. live 95% replaces future cached GO -> HOLD exit 2" test "$rc" -eq 2
  check "7. HOLD names the live 95%, not cached 5%" grep -q '^HOLD.*95% used' "$TMPROOT/future.live"
  cache="$(cachedir)"; seed_cache "$cache" "$((NOW - 60))"
  log="$TMPROOT/fresh.log"; stub="$(curl_stub 200 "$(body_both 95 200 10)" "$log")"
  run_chain - "$stub" "$cache" gate >"$TMPROOT/fresh.cached" 2>&1; rc=$?
  check "7. CONTROL ordinary one-minute-old cache still GOes (exit 0)" test "$rc" -eq 0
  check "7. CONTROL fresh cache needs no curl" test ! -e "$log"
  run_chain "$(keychain)" "$stub" "$cache" gate --fresh >"$TMPROOT/fresh.live" 2>&1; rc=$?
  check "7. --fresh steps over a warm cache, gates on live HOLD/2" test "$rc" -eq 2
  check "7. --fresh makes exactly one request" test "$(wc -l <"$log" 2>/dev/null | tr -d ' ')" = 1
  run_chain - - "$cache" read --json >"$TMPROOT/fresh.after" 2>&1; rc=$?
  check "7. fresh answer is cached for the next ordinary read" \
    json_is "$TMPROOT/fresh.after" 'd["fiveHour"]["pct"] == 95 and d["readAt"] == 1789156800'
fi

if selected uninstalled; then
  repo="$TMPROOT/uninitialized"; mkdir -p "$repo"
  git init -q "$repo"
  LCARS_ECH_CWD="$repo" bash "$ECH" status >"$TMPROOT/no-install" 2>&1; rc=$?
  check "8. ECH status in an uninitialized repo still refuses (exit 1)" test "$rc" -eq 1
  check "8. refusal names missing autopilot.json and the init command" \
    bash -c 'grep -q "no autopilot.json" "$1" && grep -q "init --spec" "$1" && ! grep -qi traceback "$1"' \
    -- "$TMPROOT/no-install"
  for cwd in "$repo" "$TMPROOT"; do
    (cd "$cwd" && SCRIPT="$ECH" run_chain - - "$(cachedir)" usage gate --json) \
      >"$TMPROOT/no-credentials" 2>"$TMPROOT/no-credentials.err"; rc=$?
    check "8. ECH usage from any cwd without credentials refuses UNKNOWN/4" test "$rc" -eq 4
    check "8. no-install account refusal is actionable JSON, not a stack trace" \
      json_is "$TMPROOT/no-credentials" \
      'd["verdict"] == "UNKNOWN" and d["exitCode"] == 4 and "Claude Code" in d["reason"]'
    check "8. no-install stderr contains no traceback" \
      bash -c '! grep -qi traceback "$1"' -- "$TMPROOT/no-credentials.err"
  done
fi

if selected mounts; then
  mkdir -p "$TMPROOT/claude-skills" "$TMPROOT/copilot-plugins" "$TMPROOT/elsewhere"
  ln -s "$ROOT/skills/lcars-eeh" "$TMPROOT/claude-skills/lcars-eeh"
  ln -s "$ROOT" "$TMPROOT/copilot-plugins/lcars"
  for entry in "$TMPROOT/claude-skills/lcars-eeh/ech.sh" \
               "$TMPROOT/copilot-plugins/lcars/skills/lcars-eeh/ech.sh"; do
    log="$TMPROOT/mount.$RANDOM.log"
    stub="$(curl_stub 200 "$(body_both 42 82 31)" "$log")"
    (cd "$TMPROOT/elsewhere" && SCRIPT="$entry" \
      run_chain "$(keychain)" "$stub" "$(cachedir)" usage read --json) \
      >"$TMPROOT/mount.json" 2>"$TMPROOT/mount.err"; rc=$?
    check "mount. ECH reaches product reader through $entry (exit 0)" test "$rc" -eq 0
    check "mount. normalised endpoint document survives farm resolution" \
      json_is "$TMPROOT/mount.json" 'd["source"] == "endpoint" and d["fiveHour"]["pct"] == 42 and d["weekly"]["pct"] == 31'
    (cd "$TMPROOT/elsewhere" && env -u CHAIN_CONFIG bash "$entry" usage config) \
      >"$TMPROOT/mount.config" 2>&1
    check "mount. farm resolves product usage.json, not cwd or a second reader" \
      grep -q 'weekly limit is >= 95%' "$TMPROOT/mount.config"
  done
fi

printf '\nlcars-usage: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
