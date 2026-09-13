#!/usr/bin/env bash
#
# Tests for THE ONE state.json writer family (S207 item 5).
#
# state.json is edited by eight different scripts. Until this session each one
# carried its OWN copy of a line-based `state_del` / `state_set_str` /
# `state_set_raw` trio:
#
#     state_del() { grep -v "\"$1\"[[:space:]]*:" "$STATE" >tmp && mv tmp "$STATE"; }
#
# and re-inserted the field after line 1 WITH A HARD-CODED TRAILING COMMA. Both
# halves are shape-dependent:
#
#   * deleting the LAST key of the object leaves the previous line's separator
#     comma dangling → `{ "a": 1, }` → INVALID JSON;
#   * `state_set_str` calls `state_del` first, so every set of the last key goes
#     through that same window.
#
# S189 found it (the viewscreen silently lost a refreshed mission), cured the
# adopt.sh copy, and LEDGERED the rest: "fix all writers together, one session".
# S202 made it reachable in ordinary use — answering a gate clears
# `awaitingHuman` / `pendingQuestion`, either of which can be the last key — and
# LCARS's own sed-based readers are lenient enough that the corruption is
# SILENT. This is that session.
#
# The rule every check below enforces: after ANY write, `json.load` must parse
# the file. The S189 lesson is that a hundred greps cannot see a trailing comma.
#
# Behaviours under test:
#   1. set the FIRST / a MIDDLE / the LAST key — valid JSON, value applied,
#      field order preserved, in place
#   2. add a NEW key — valid JSON, lands at the top (the S189 convention)
#   3. all of the above on a file with NO trailing newline
#   4. delete the FIRST / a MIDDLE / the LAST / the ONLY key — valid JSON
#   5. raw (unquoted) values: true / false / numbers / a one-line object
#   6. hostile string values (quotes, backslashes, newlines, control chars)
#   7. the one-line `numberOne` block stays ONE line (state_xo_block seds it)
#   8. NO script carries a private copy of the writer any more
#   9. approve.sh's `review "merged"` with `review` as the LAST key — the named
#      regression, and the exact shape that breaks today
#  10. the other live verbs (pause / respond / run) through their last key
#
# Zero tokens, zero network: nothing here spawns a worker.
#
# Usage: bash tests/lcars-state-writer.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
APPROVE="$REPO_ROOT/skills/lcars-approve/approve.sh"
PAUSE="$REPO_ROOT/skills/lcars-pause/pause.sh"
RESPOND="$REPO_ROOT/skills/lcars-respond/respond.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# The ONLY acceptance oracle that matters: a real JSON parser.
parses() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }
jget()   { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get(sys.argv[2])))' "$1" "$2" 2>/dev/null; }
jkeys()  { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).keys()))' "$1" 2>/dev/null; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required to VERIFY (not to run) the writer"; exit 1; }

# A state.json of the shape file.sh writes: one field per line, `{` alone on
# line 1, `}` alone on the last.
new_state() { # path
  cat >"$1" <<'EOF'
{
  "id": "lcars-20260601-001",
  "type": "feature",
  "title": "Add gamification",
  "stage": "verify",
  "created": "2026-06-01T10:00:00Z",
  "review": "pending"
}
EOF
}
# The same object with NO trailing newline after the closing brace.
new_state_no_nl() { new_state "$1"; printf '%s' "$(cat "$1")" >"$1.t"; mv "$1.t" "$1"; }

# ==========================================================================
echo "lcars state writer (S207 item 5)"

[ -f "$COMMON" ] || { echo "lcars-common.sh not found at $COMMON"; exit 1; }

# The family must exist, be sourceable, and be the ONE home.
# shellcheck source=../skills/lcars-init/lcars-common.sh
. "$COMMON" 2>/dev/null || true

check "0. lcars_state_set is defined by lcars-common.sh" \
  "declare -F lcars_state_set >/dev/null"
check "0. lcars_state_set_string is defined by lcars-common.sh" \
  "declare -F lcars_state_set_string >/dev/null"
check "0. lcars_state_unset is defined by lcars-common.sh" \
  "declare -F lcars_state_unset >/dev/null"

# --- Behaviour 1: set FIRST / MIDDLE / LAST --------------------------------
for pos in first middle last; do
  case "$pos" in
    first)  key=id;     want='"zzz"' ;;
    middle) key=stage;  want='"done"' ;;
    last)   key=review; want='"merged"' ;;
  esac
  f="$TMPROOT/set-$pos.json"; new_state "$f"
  lcars_state_set_string "$f" "$key" "${want//\"/}" 2>/dev/null
  check "1. set the $pos key ($key) leaves VALID JSON" "parses '$f'"
  check "1. set the $pos key ($key) applies the value" \
    "[ \"\$(jget '$f' $key)\" = '$want' ]"
  check "1. set the $pos key ($key) keeps the field order" \
    "[ \"\$(jkeys '$f')\" = 'id,type,title,stage,created,review' ]"
done

# --- Behaviour 2: add a NEW key --------------------------------------------
f="$TMPROOT/add.json"; new_state "$f"
lcars_state_set_string "$f" prUrl "https://example.test/pull/9" 2>/dev/null
check "2. adding a NEW key leaves VALID JSON" "parses '$f'"
check "2. the new key holds its value" \
  "[ \"\$(jget '$f' prUrl)\" = '\"https://example.test/pull/9\"' ]"
check "2. the new key lands at the TOP (the S189 convention)" \
  "[ \"\$(jkeys '$f' | cut -d, -f1)\" = 'prUrl' ]"

# --- Behaviour 3: no trailing newline --------------------------------------
for pos in first last new; do
  f="$TMPROOT/nonl-$pos.json"; new_state_no_nl "$f"
  case "$pos" in
    first) lcars_state_set_string "$f" id nnn 2>/dev/null ;;
    last)  lcars_state_set_string "$f" review merged 2>/dev/null ;;
    new)   lcars_state_set_string "$f" prUrl u 2>/dev/null ;;
  esac
  check "3. set the $pos key on a file with NO trailing newline → VALID JSON" \
    "parses '$f'"
done

# --- Behaviour 4: delete FIRST / MIDDLE / LAST / ONLY ----------------------
for pos in first middle last; do
  case "$pos" in first) key=id ;; middle) key=stage ;; last) key=review ;; esac
  f="$TMPROOT/del-$pos.json"; new_state "$f"
  lcars_state_unset "$f" "$key" 2>/dev/null
  check "4. delete the $pos key ($key) leaves VALID JSON" "parses '$f'"
  check "4. delete the $pos key ($key) removes it" \
    "[ \"\$(jget '$f' $key)\" = 'null' ]"
done
f="$TMPROOT/del-only.json"
printf '{\n  "solo": "x"\n}\n' >"$f"
lcars_state_unset "$f" solo 2>/dev/null
check "4. delete the ONLY key leaves VALID JSON (an empty object)" "parses '$f'"
check "4. delete a key that is NOT there is a clean no-op" \
  "f2='$TMPROOT/del-absent.json'; new_state \"\$f2\"; lcars_state_unset \"\$f2\" nosuch 2>/dev/null; parses \"\$f2\" && [ \"\$(jkeys \"\$f2\")\" = 'id,type,title,stage,created,review' ]"

# --- Behaviour 5: raw values ------------------------------------------------
f="$TMPROOT/raw.json"; new_state "$f"
lcars_state_set "$f" awaitingHuman true 2>/dev/null
lcars_state_set "$f" githubIssue 7 2>/dev/null
lcars_state_set "$f" review '"merged"' 2>/dev/null
check "5. raw true / number / quoted-string writes leave VALID JSON" "parses '$f'"
check "5. a raw true is a JSON boolean, not a string" \
  "[ \"\$(jget '$f' awaitingHuman)\" = 'true' ]"
check "5. a raw number is a JSON number" "[ \"\$(jget '$f' githubIssue)\" = '7' ]"
check "5. a raw quoted value sets the LAST key and still parses" \
  "[ \"\$(jget '$f' review)\" = '\"merged\"' ]"
# a raw ONE-LINE object on the LAST key (the numberOne / baseFreshness shape)
f="$TMPROOT/raw-obj.json"; new_state "$f"
lcars_state_set "$f" review '{"status": "engaged", "since": "now"}' 2>/dev/null
check "5. a one-line OBJECT on the LAST key leaves VALID JSON" "parses '$f'"

# --- Behaviour 6: hostile string values ------------------------------------
f="$TMPROOT/hostile.json"; new_state "$f"
lcars_state_set_string "$f" review 'he said "hi", then \ left
on a new line	tabbed' 2>/dev/null
check "6. a value with quotes / backslash / newline / tab → VALID JSON" "parses '$f'"
check "6. the hostile value round-trips as ONE string" \
  "python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))[\"review\"].startswith(\"he said\")' '$f'"
f="$TMPROOT/hostile2.json"; new_state "$f"
lcars_state_set_string "$f" title 'ends with a comma,' 2>/dev/null
lcars_state_set_string "$f" review 'also ends with a comma,' 2>/dev/null
check "6. values that END in a comma do not lose a character" \
  "parses '$f' && [ \"\$(jget '$f' review)\" = '\"also ends with a comma,\"' ]"

# --- Behaviour 7: the one-line numberOne block stays on ONE line -----------
f="$TMPROOT/xo.json"; new_state "$f"
lcars_state_set "$f" numberOne '{"status": "engaged", "engine": "claude"}' 2>/dev/null
lcars_state_set_string "$f" review merged 2>/dev/null
check "7. numberOne survives a later write as ONE line" \
  "parses '$f' && [ \"\$(grep -c '\"numberOne\"' '$f')\" = 1 ] && grep -q '\"numberOne\": {.*}' '$f'"
check "7. the sed-based block reader still finds it" \
  "[ -n \"\$(sed -n 's/.*\"numberOne\"[[:space:]]*:[[:space:]]*\\({[^}]*}\\).*/\\1/p' '$f' | head -1)\" ]"

# --- Behaviour 8: no script carries a private copy --------------------------
check "8. no 'state_set_str()' definition survives anywhere under skills/" \
  "[ \"\$(grep -rc 'state_set_str()' '$REPO_ROOT/skills/' 2>/dev/null | awk -F: '{s+=\$2} END{print s+0}')\" = 0 ]"
check "8. no 'state_set_raw()' definition survives anywhere under skills/" \
  "[ \"\$(grep -rc 'state_set_raw()' '$REPO_ROOT/skills/' 2>/dev/null | awk -F: '{s+=\$2} END{print s+0}')\" = 0 ]"
check "8. no 'state_del()' definition survives anywhere under skills/" \
  "[ \"\$(grep -rc 'state_del()' '$REPO_ROOT/skills/' 2>/dev/null | awk -F: '{s+=\$2} END{print s+0}')\" = 0 ]"
check "8. no grep -v line-deleter survives anywhere under skills/" \
  "! grep -rq 'grep -v \"\\\\\"\\\$1\\\\\"\\[\\[:space:\\]\\]\\*:\"' '$REPO_ROOT/skills/' 2>/dev/null"

# ==========================================================================
# --- Behaviour 9: THE NAMED REGRESSION — approve's merged path -------------
# `review` is the LAST key of the object; approve's ship path writes it. Today
# that is `state_del review` (drops the last line, leaving `"created": ...,` as
# ==========================================================================
MID="lcars-20260601-001"
# A gh that succeeds at everything, including `pr merge`, and logs every call.
make_gh_stub() {
  cat >"$1" <<'GHEOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
exit 0
GHEOF
  chmod +x "$1"
}

# A mission parked at verify with an OPEN PR recorded — the shape Verify leaves
# behind — and with `review` DELIBERATELY THE LAST FIELD of the object. That is
# the only difference from tests/lcars-approve.test.sh's fixture, and it is the
# whole point: approve's ship path writes `review`, and today that write goes
# through a delete-the-last-line window.
new_repo_review_last() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q -b "lcars/$MID" \
      && printf 'export const theme = "dark";\n' >theme.js \
      && git add -A && git commit -q -m "lcars($MID) t-001" \
      && git checkout -q "$base" )
  local m="$repo/.git/lcars/missions/$MID"; mkdir -p "$m"
  cat >"$m/prd.md" <<'PRDEOF'
# Mission: Add dark mode
**Type:** feature
**Goal:** Let users switch to a dark colour scheme.
**Acceptance Criteria:**
- A toggle persists the choice
PRDEOF
  cat >"$m/state.json" <<STEOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "verify",
  "prUrl": "https://github.com/acme/repo/pull/77",
  "prNumber": 77,
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42,
  "branch": "lcars/$MID",
  "base": "$base",
  "review": "open"
}
STEOF
  printf '%s\n' "$repo"
}

# --- Behaviour 9: THE NAMED REGRESSION — approve's merged path -------------
repo9="$(new_repo_review_last)"; make_gh_stub "$repo9/gh"
# a reconcile stub, so approve's self-heal never reaches the real run.sh
cat >"$repo9/recon.sh" <<'RCEOF'
#!/usr/bin/env bash
exit 0
RCEOF
chmod +x "$repo9/recon.sh"
export GH_LOG="$repo9/gh.log"; : >"$GH_LOG"
( cd "$repo9" && LCARS_GH_BIN="$repo9/gh" LCARS_RUN_SCRIPT="$repo9/recon.sh" \
    bash "$APPROVE" --mission "$MID" >"$repo9/out.txt" 2>&1 ) || true
s9="$repo9/.git/lcars/missions/$MID/state.json"
check "9. approve reached the merge" "grep -q 'pr merge' '$repo9/gh.log'"
check "9. approve's merged path leaves state.json VALID JSON (review was LAST)" \
  "parses '$s9'"
check "9. approve recorded review=merged" "[ \"\$(jget '$s9' review)\" = '\"merged\"' ]"
check "9. approve recorded stage=done"    "[ \"\$(jget '$s9' stage)\" = '\"done\"' ]"

# --- Behaviour 10: the other live verbs through their last key -------------
# pause writes `paused` (raw); plant it LAST so resume's clear hits the window.
repoP="$(new_repo_review_last)"; make_gh_stub "$repoP/gh"
export GH_LOG="$repoP/gh.log"; : >"$GH_LOG"
sP="$repoP/.git/lcars/missions/$MID/state.json"
( cd "$repoP" && LCARS_GH_BIN="$repoP/gh" bash "$PAUSE" pause "$MID" >/dev/null 2>&1 ) || true
check "10. pause leaves state.json VALID JSON" "parses '$sP'"
python3 "$REPO_ROOT/tests/fixtures/lcars-state-writer-last.py" "$sP" paused true
( cd "$repoP" && LCARS_GH_BIN="$repoP/gh" LCARS_RUN_SCRIPT=/usr/bin/true \
    bash "$PAUSE" resume "$MID" >/dev/null 2>&1 ) || true
check "10. resume clearing 'paused' as the LAST key leaves VALID JSON" "parses '$sP'"
check "10. resume really cleared the flag" "[ \"\$(jget '$sP' paused)\" != 'true' ]"

# respond clears awaitingHuman THEN pendingQuestion — in the canonical gate
# shape (run.sh's own writer leaves them at the end) pendingQuestion IS the last
# key, so the second delete is the corrupting one.
repoR="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
( cd "$repoR" && git init -q && git config user.email t@t && git config user.name t )
mR="$repoR/.git/lcars/missions/$MID"; mkdir -p "$mR"
cat >"$mR/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add gamification",
  "stage": "validate",
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42,
  "awaitingHuman": true,
  "pendingQuestion": "Global or per-course leaderboard?"
}
EOF
cat >"$mR/pending.json" <<'EOF'
{
  "stage": "validate",
  "questions": [
    "Global or per-course leaderboard?"
  ]
}
EOF
make_gh_stub "$repoR/gh"; export GH_LOG="$repoR/gh.log"; : >"$GH_LOG"
sR="$mR/state.json"
( cd "$repoR" && LCARS_GH_BIN="$repoR/gh" bash "$RESPOND" answer \
    --mission "$MID" --answer "per-course" >"$repoR/out.txt" 2>&1 ) || true
check "10. respond clearing the gate (pendingQuestion LAST) leaves VALID JSON" \
  "parses '$sR'"
check "10. respond really cleared the gate" "[ \"\$(jget '$sR' awaitingHuman)\" != 'true' ]"
check "10. respond really cleared pendingQuestion" \
  "[ \"\$(jget '$sR' pendingQuestion)\" = 'null' ]"

# --- Behaviour 11 (S207 fix round 1, D2): THE RETURN CODE IS THE CONTRACT ---
# The writer used to return 0 unconditionally, refusals included, so a caller
# had no way to tell a write from a warning it never saw. `lcars pause` printed
# "PAUSE: paused …" over a refused write and exited 0. The rc now distinguishes
# the three outcomes, and only the REFUSAL is non-zero.
w11="$TMPROOT/rc.json"

new_state "$w11"
lcars_state_set "$w11" paused true
check "11. a SUCCESSFUL write returns 0" "[ \"\$?\" -eq 0 ]"

new_state "$w11"
lcars_state_unset "$w11" nosuchkeyatall
check "11. unsetting an ABSENT key returns 0 (nothing to do is not a refusal)" \
  "[ \"\$?\" -eq 0 ]"
check "11. …and leaves the object VALID and unchanged in field count" \
  "parses '$w11'"

# A REFUSAL: valid JSON, wrong shape. This is the tester's `lcars pause` case.
printf '{"id":"m","stage":"plan","base":"main"}\n' >"$w11"
rc11=0; lcars_state_set "$w11" paused true 2>"$TMPROOT/rc.err" || rc11=$?
check "11. a REFUSED write returns NON-ZERO" "[ '$rc11' -ne 0 ]"
check "11. …still warns on stderr (the loud no-op is kept)" \
  "grep -q 'NOT written' '$TMPROOT/rc.err'"
check "11. …and still leaves the file untouched" \
  "[ \"\$(cat '$w11')\" = '{\"id\":\"m\",\"stage\":\"plan\",\"base\":\"main\"}' ]"
check "11. …and LATCHES the refusal for the verb to read" \
  "[ -n \"\${LCARS_STATE_REFUSED:-}\" ]"
check "11. the latch names the file and the field it refused" \
  "printf '%s' \"\$LCARS_STATE_REFUSED\" | grep -q 'paused'"

# The helper every verb uses. It is a NO-OP when nothing was refused — which is
# the property that makes it safe to put on a success path at all.
LCARS_STATE_REFUSED=""
( lcars_state_refusal_die "lcars test" ) >/dev/null 2>&1
check "11. lcars_state_refusal_die is a clean no-op with no refusal on file" \
  "[ \"\$?\" -eq 0 ]"
LCARS_STATE_REFUSED="somewhere/state.json (field \"paused\")"
rcD=0; ( lcars_state_refusal_die "lcars pause" ) >"$TMPROOT/die.out" 2>&1 || rcD=$?
check "11. …and EXITS NON-ZERO once a refusal is latched" "[ '$rcD' -ne 0 ]"
check "11. …saying REFUSED, in the captain's words" \
  "grep -q 'REFUSED' '$TMPROOT/die.out'"
check "11. …naming the verb he typed" "grep -q 'lcars pause' '$TMPROOT/die.out'"
check "11. …and telling him nothing was changed" \
  "grep -qi 'NOT changed' '$TMPROOT/die.out'"
LCARS_STATE_REFUSED=""

# NO FILE AT ALL stays 0, deliberately: several callers resolve a mission by
# directory and call through with no state.json, and that is their guard, not a
# refused write. Pinned here so the distinction is not lost by accident.
rcN=0; lcars_state_set "$TMPROOT/definitely-not-here.json" paused true || rcN=$?
check "11. writing to a file that does not exist stays 0 (a caller's guard)" \
  "[ '$rcN' -eq 0 ]"
check "11. …and latches NOTHING" "[ -z \"\${LCARS_STATE_REFUSED:-}\" ]"

# ==========================================================================
echo
printf 'lcars state writer: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
