#!/usr/bin/env bash
# DRIVE 5 (fix round 2) — THE REFRESH CURE, MEASURED WHERE IT ACTUALLY HURT.
#
# Round 1's ship-blocker was: `lcars adopt` on an ALREADY-ADOPTED mission wrote
# a trailing comma into state.json. `lcars status` (sed) never noticed; the
# VIEWSCREEN BOARD parses it with json.load and the card silently VANISHED.
#
# Round 1 verified the cure by calling LocalAdapter.board() in-process, and said
# so as its own blind spot. THIS drive goes one level more real: it starts an
# ACTUAL viewscreen daemon on a free port inside laptop B and GETs /api/board
# over HTTP after EVERY adopt. Only the PID this drive starts is killed, by PID.
#
#   1. adopt ×3 on a real Verify mission — valid JSON + card ON THE BOARD after
#      each; adopt 2 and 3 byte-identical; local-only fields survive.
#   2. THE CURE'S OWN NEW RISK — the cure deliberately keeps `base` LAST, because
#      five sibling files still carry the flawed helper and are latent only while
#      that holds. A REAL `approve` (merge FUSED OFF) writes four fields through
#      one of those siblings: state.json must still parse, and `review` must not
#      have become the last field.
#   3. CURE 2 ON THE REAL SURFACE — adopt writes prNumber as a STRING (matching
#      pr-lib.sh:217), so approve's bare-token reader returns "" and it merges by
#      `--head <branch>`. That selector must resolve the REAL PR, and must NOT
#      resolve a decoy PR that merely mentions the issue.
#
# Substrate: the mission ends-e2e.sh left at Verify (last-issue/last-mid/last-pr).
# NOTHING IS EVER MERGED.
. "$(dirname "$0")/lib.sh"

ISSUE="$(cat "$S189_HOME/last-issue" 2>/dev/null)"
MID="$(cat "$S189_HOME/last-mid" 2>/dev/null)"
PRNUM="$(cat "$S189_HOME/last-pr" 2>/dev/null)"
[ -n "$ISSUE" ] && [ -n "$MID" ] && [ -n "$PRNUM" ] || { echo "run ends-e2e.sh first"; exit 1; }

B="$(laptop B)"
reset_laptop "$B"          # laptop B starts with NO .git/lcars at all
lcars_config "$B"          # …then initialised, which is the board's real premise
BMDIR="$B/.git/lcars/missions/$MID"
STATEF="$BMDIR/state.json"
DECOY_BRANCH="s189r2/decoy-mentions-$ISSUE"
CLEANUP_PRS=""

# ---------------------------------------------------------------- assertions
jsonok() { # <file> <label> — the check `lcars status` cannot make
  local err
  if err="$(python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>&1)"; then
    ok "$2: state.json is VALID JSON (python json.load)"
  else
    bad "$2: state.json is INVALID JSON — $err"
    sed 's/^/      /' "$1"
  fi
}
keys_of() { python3 -c '
import json,sys
try: print(" ".join(json.load(open(sys.argv[1])).keys()))
except Exception as e: print("UNPARSEABLE:"+type(e).__name__)' "$1"; }
last_key() { keys_of "$1" | awk '{print $NF}'; }

# ------------------------------------------------- a REAL viewscreen daemon
VS_LOG="$WORK/viewscreen.log"; VS_PID=""; BOARD_URL=""
start_viewscreen() {
  # `exec env … bash …` so the BACKGROUNDED SUBSHELL *becomes* the launcher,
  # which itself execs python: $! is then the DAEMON's own pid. Without the
  # exec, bash forks python as a child and `kill $!` reaps only the wrapper —
  # the daemon survives as an orphan still holding the port. (This drive did
  # exactly that on its first run; the leak is the reason the exec is here.)
  ( cd "$B" && exec env LCARS_VIEWSCREEN_ALLOW_AI=1 LCARS_SERVE_NO_OPEN=1 \
      LCARS_SERVE_PORT=0 LCARS_SERVE_ADAPTER=local LCARS_VERSION_CHECK=0 \
      bash "$LCARS_SRC/skills/lcars-viewscreen/viewscreen.sh" </dev/null >"$VS_LOG" 2>&1 ) &
  VS_PID=$!
  local i=0
  while [ "$i" -lt 60 ]; do
    BOARD_URL="$(sed -n 's|.*— \(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$VS_LOG" | head -1)"
    [ -n "$BOARD_URL" ] && break
    kill -0 "$VS_PID" 2>/dev/null || break
    sleep 0.25; i=$((i+1))
  done
  [ -n "$BOARD_URL" ]
}
stop_viewscreen() { # ONLY the pid we started, BY PID. Never by name/pattern.
  [ -n "$VS_PID" ] || return 0
  kill "$VS_PID" 2>/dev/null
  local i=0; while kill -0 "$VS_PID" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.25; i=$((i+1)); done
  kill -0 "$VS_PID" 2>/dev/null && kill -9 "$VS_PID" 2>/dev/null
  note "viewscreen pid $VS_PID stopped (killed by PID, nothing else touched)"
  VS_PID=""
  # DAEMON HYGIENE, asserted: nothing may still be listening on the port this
  # drive opened. (A wrapper-only kill would leave an orphan holding it.)
  local port="${BOARD_URL##*:}"; port="${port%%/*}"
  if [ -n "$port" ]; then
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      bad "a process is STILL listening on port $port — this drive orphaned its daemon"
    else
      ok "port $port is free — no orphaned daemon left behind"
    fi
  fi
}
board_has() { # <label> — GET /api/board over HTTP and look for the card
  local out ids
  out="$(curl -sS --max-time 10 "${BOARD_URL}api/board" 2>"$WORK/curl.err")"
  if [ -z "$out" ]; then bad "$1: /api/board returned nothing ($(head -1 "$WORK/curl.err"))"; return 1; fi
  printf '%s' "$out" >"$WORK/board.json"
  ids="$(MID="$MID" python3 -c '
import json,os,sys
b=json.load(open(sys.argv[1]))
ids=[c["id"] for col in b["columns"].values() for c in col]
print("IDS "+" ".join(ids))
print("PRESENT" if os.environ["MID"] in ids else "MISSING")
for col,cards in b["columns"].items():
    for c in cards:
        if c["id"]==os.environ["MID"]: print("COLUMN "+col)
' "$WORK/board.json" 2>&1)"
  note "$(printf '%s' "$ids" | tr '\n' '|')"
  case "$ids" in
    *PRESENT*) ok "$1: the card IS on the live board (HTTP GET /api/board)"; return 0 ;;
    *) bad "$1: the card is NOT on the live board"; return 1 ;;
  esac
}

trap 'stop_viewscreen' EXIT

hdr "PREMISE — a real mission at Verify, laptop B wiped clean"
note "issue #$ISSUE  mission $MID  real PR #$PRNUM"
[ -d "$B/.git/lcars/missions" ] && [ -z "$(ls -A "$B/.git/lcars/missions" 2>/dev/null)" ] \
  && ok "laptop B holds no missions" || bad "laptop B is not clean"

hdr "THE VIEWSCREEN — a REAL daemon, on a free port, inside laptop B"
if start_viewscreen; then
  ok "daemon up on $BOARD_URL (pid $VS_PID)"
  note "$(head -3 "$VS_LOG" | tr '\n' ' ')"
else
  bad "viewscreen would not start"; sed 's/^/    /' "$VS_LOG" | head -20; exit 1
fi
mode="$(curl -sS --max-time 10 "${BOARD_URL}api/board" | python3 -c 'import json,sys; b=json.load(sys.stdin); print(b["meta"]["adapter"], b["meta"].get("mode"))' 2>&1)"
note "board meta: $mode"

# ===========================================================================
# 1. ADOPT ×3 — valid JSON and ON THE BOARD after every one
# ===========================================================================
for n in 1 2 3; do
  hdr "ADOPT #$n — lcars adopt $ISSUE on laptop B"
  ( cd "$B" && bash "$ADOPT_SH" "$ISSUE" ) >"$WORK/adopt$n.out" 2>&1
  rc=$?
  note "adopt rc=$rc"
  sed 's/^/    /' "$WORK/adopt$n.out" | head -12
  [ "$rc" = 0 ] && ok "adopt #$n rc=0" || bad "adopt #$n rc=$rc"
  [ -f "$STATEF" ] && ok "adopt #$n: state.json exists" || { bad "adopt #$n: no state.json"; continue; }
  jsonok "$STATEF" "adopt #$n"
  lk="$(last_key "$STATEF")"
  [ "$lk" = base ] && ok "adopt #$n: LAST field is still \`base\` (what keeps the 5 unfixed siblings latent)" \
    || bad "adopt #$n: last field is '$lk', not 'base'"
  note "keys: $(keys_of "$STATEF")"
  board_has "adopt #$n"
  cp "$STATEF" "$WORK/state.after$n.json"

  if [ "$n" = 1 ]; then
    hdr "LOCAL-ONLY FIELDS — injected after adopt #1, must survive #2 and #3"
    # Exactly the kind of field the refresh path promises to leave untouched:
    # an estimate's model override and a recorded base sha. Added the way LCARS's
    # own writers add one (top of the object).
    st_add "$STATEF" '"modelOverride": "opus"'
    st_add "$STATEF" '"baseSha": "c6f9f2390f4f692c568598e435deab25ccfc3c88"'
    jsonok "$STATEF" "after injecting local-only fields"
    note "keys now: $(keys_of "$STATEF")"
  fi
done

hdr "BYTE-STABILITY — a repeat adopt must not churn the file"
if cmp -s "$WORK/state.after2.json" "$WORK/state.after3.json"; then
  ok "adopt #2 and adopt #3 produced a BYTE-IDENTICAL state.json"
else
  bad "adopt #3 changed the file adopt #2 wrote"
  diff "$WORK/state.after2.json" "$WORK/state.after3.json" | sed 's/^/    /' | head -20
fi

hdr "LOCAL-ONLY FIELDS SURVIVED the refreshes"
for f in modelOverride baseSha; do
  v="$(st_get "$STATEF" "$f")"
  [ -n "$v" ] && ok "$f survived ('$v')" || bad "$f was destroyed by the refresh"
done
note "final state: $(tr -d '\n' <"$STATEF")"

# ===========================================================================
# 2/3. A REAL APPROVE — merge FUSED OFF. The sibling-helper risk, and the
#      --head fallback resolving the REAL PR and not a decoy.
# ===========================================================================
hdr "THE DECOY PR — a second REAL pull request that merely MENTIONS #$ISSUE"
fixture_drop_branch "$DECOY_BRANCH"
( cd "$B" && git checkout -q main \
    && git checkout -q -B "$DECOY_BRANCH" origin/main \
    && printf 'a decoy, unrelated to the mission\n' > DECOY-NOTES.md \
    && git add -A && git commit -q -m "chore: unrelated note that mentions #$ISSUE" \
    && git push -q -u origin "$DECOY_BRANCH" && git checkout -q main ) >"$WORK/decoy.git" 2>&1 \
  || { bad "could not push the decoy branch"; sed 's/^/    /' "$WORK/decoy.git" | head; }
DECOY_URL="$("$GH_REAL" pr create -R "$FIXTURE" --base main --head "$DECOY_BRANCH" \
    --title "chore: a note that mentions #$ISSUE" \
    --body "This PR only MENTIONS #$ISSUE. It does not close it and is not the mission's PR." 2>"$WORK/decoy.err")"
DECOY_NUM="${DECOY_URL##*/}"
case "$DECOY_NUM" in
  ''|*[!0-9]*) bad "decoy PR not created: $(head -2 "$WORK/decoy.err")"; DECOY_NUM="" ;;
  *) ok "decoy PR #$DECOY_NUM opened ($DECOY_URL)"; CLEANUP_PRS="$DECOY_NUM" ;;
esac

hdr "RE-ADOPT with the decoy in play — the mission's PR must still be #$PRNUM"
( cd "$B" && bash "$ADOPT_SH" "$ISSUE" ) >"$WORK/adopt4.out" 2>&1
note "adopt rc=$?"
apn="$(st_get "$STATEF" prNumber)"
[ "$apn" = "$PRNUM" ] && ok "adopt still resolved the REAL PR (#$apn), not the decoy (#$DECOY_NUM)" \
  || bad "adopt resolved prNumber='$apn' (real=$PRNUM decoy=$DECOY_NUM)"
grep -q "\"prNumber\"[[:space:]]*:[[:space:]]*\"" "$STATEF" \
  && ok "prNumber is a JSON STRING (cure 2 — matches pr-lib.sh:217)" \
  || bad "prNumber is not a string"
PRN_RAW="$(st_raw "$STATEF" prNumber)"
[ -z "$PRN_RAW" ] && ok "approve's bare-token reader sees '' → it WILL take the --head fallback" \
  || note "bare-token reader returned '$PRN_RAW'"
jsonok "$STATEF" "after the decoy re-adopt"
board_has "after the decoy re-adopt"

hdr "\`gh pr merge <branch>\` — does the SELECTOR resolve the real PR?"
BRANCH="$(st_get "$STATEF" branch)"
RESOLVED="$("$GH_REAL" pr view "$BRANCH" -R "$FIXTURE" --json number -q .number 2>&1)"
[ "$RESOLVED" = "$PRNUM" ] && ok "\`pr view $BRANCH\` resolves to the REAL PR #$RESOLVED" \
  || bad "the branch selector resolves to '$RESOLVED', expected #$PRNUM"
[ "$RESOLVED" = "$DECOY_NUM" ] && bad "the branch selector resolved the DECOY" \
  || ok "the branch selector is NOT the decoy"

hdr "A REAL \`lcars approve\` — merge FUSED OFF (nothing is merged)"
LAST_BEFORE="$(last_key "$STATEF")"
note "last field before approve: $LAST_BEFORE"
MERGELOG="$WORK/merge.log"; : >"$MERGELOG"
cat >"$WORK/gh-nomerge" <<FUSE
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"$GH_LOG"
if [ "\${1:-}" = pr ] && [ "\${2:-}" = merge ]; then
  printf 'MERGE-ATTEMPT\t%s\n' "\$*" >>"$MERGELOG"
  echo "s189 tester: merge fuse — refusing to merge the fixture PR" >&2
  exit 1
fi
exec "$GH_REAL" "\$@"
FUSE
chmod +x "$WORK/gh-nomerge"
( cd "$B" && LCARS_GH_BIN="$WORK/gh-nomerge" LCARS_MERGE_RETRIES=1 LCARS_MERGE_RETRY_SLEEP=0 \
    bash "$APPROVE_SH" --mission "$MID" ) >"$WORK/approve.out" 2>&1
note "approve rc=$?"
sed 's/^/    /' "$WORK/approve.out" | head -20
if [ -s "$MERGELOG" ]; then
  note "$(cat "$MERGELOG")"
  grep -qE "MERGE-ATTEMPT	pr merge $BRANCH( |\$)" "$MERGELOG" \
    && ok "approve reached \`gh pr merge $BRANCH\` — the --head fallback cure 2 forces" \
    || bad "merge attempt did not use the branch selector"
  grep -qE "MERGE-ATTEMPT	pr merge $DECOY_NUM( |\$)" "$MERGELOG" \
    && bad "approve tried to merge the DECOY PR" || ok "approve never named the decoy"
else
  bad "approve never reached the merge"
fi

hdr "THE CURE'S OWN NEW RISK — the object after a SIBLING helper wrote to it"
jsonok "$STATEF" "after approve (4 fields via approve.sh's unfixed helper)"
LAST_AFTER="$(last_key "$STATEF")"
[ "$LAST_AFTER" = base ] && ok "last field is STILL \`base\` after approve" \
  || bad "last field is now '$LAST_AFTER'"
[ "$LAST_AFTER" = review ] && bad "\`review\` became the last field — the latent sibling bug is now armed" \
  || ok "\`review\` did NOT become the last field"
note "keys after approve: $(keys_of "$STATEF")"
board_has "after approve"
st="$(st_get "$STATEF" stage)"
[ "$st" = verify ] && ok "mission still at verify (the fused merge faked no Done)" || bad "stage is '$st'"
prstate="$("$GH_REAL" pr view "$PRNUM" -R "$FIXTURE" --json state -q .state 2>/dev/null)"
[ "$prstate" = OPEN ] && ok "the real PR #$PRNUM is still OPEN — nothing was merged" || bad "PR #$PRNUM state is '$prstate'"

hdr "TEARDOWN of this drive's own litter"
stop_viewscreen
for p in $CLEANUP_PRS; do "$GH_REAL" pr close "$p" -R "$FIXTURE" >/dev/null 2>&1 && note "closed decoy PR #$p"; done
fixture_drop_branch "$DECOY_BRANCH"
( cd "$B" && git checkout -q main && git branch -qD "$DECOY_BRANCH" ) >/dev/null 2>&1
note "decoy branch removed"

hdr "SPEND"; note "worker spawns: $(spawns)   billable(--model): $(billable)   gh calls: $(gh_calls)"
printf '\n%d passed, %d failed\nWORK=%s\n' "$PASS" "$FAIL" "$WORK"
