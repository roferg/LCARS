#!/usr/bin/env bash
#
# Tests for `lcars adopt <issue#>` — Session 189, leg B.
#
# Skill sources under test:
#   skills/lcars-adopt/adopt.sh        the new verb
#   skills/lcars-run/host-adapter.sh   the four READ ops adopt needs
#                                        issue-body      <n>
#                                        issue-title     <n>
#                                        issue-labels    <n>
#                                        issue-closing-prs <n>
#
# WHAT ADOPT IS. A second laptop has NO .git/lcars at all, so a mission that
# plainly exists on GitHub is invisible to it. `lcars adopt <issue#>` rebuilds
# the mission locally AT THE ENDS OF THE PIPELINE — Align (claim it and rebuild
# the spec) and Verify (join it, resolve the open PR so approve/feedback work
# immediately). Every other stage is refused: the captain's v1 boundary is the
# ends, and mid-pipeline handoff is LEDGERED, not built.
#
# ---------------------------------------------------------------------------
# THE TWO RULINGS THIS SUITE EXISTS TO PIN
# ---------------------------------------------------------------------------
#
# RULING 1 — THE STAGE COMES FROM THE LABEL, NOT THE ENVELOPE. The S188
# envelope carries id/branch/base/type/engine/parentIssue/attachments/parked and
# deliberately NO stage: the body is refreshed at exactly TWO transfer points, so
# an envelope stage would be STALE mid-pipeline by construction. The `lcars:<stage>`
# LABEL is swapped at every stage transition and is already what the github board
# adapter treats as the canonical remote stage. One source per fact. Behaviours
# S1/S2/S3 below pin that adopt reads the LABEL and that a label/envelope
# disagreement can never arise because the envelope simply has no opinion.
#
# RULING 2 — ADOPT NEVER RE-SCANS THE CAPTAIN'S PROSE. Every field adopt rebuilds
# comes from the ENVELOPE (a recorded fact) or the LABEL (a recorded fact). It
# never greps the issue's prose to recover the branch, the type, the estimate, or
# where the PRD ends. The captain writes PRDs *about LCARS*, so any regex over his
# prose will eventually be handed a document containing the very words it keys on
# — behaviour P1 hands adopt exactly that document (a PRD quoting a DECOY
# envelope and talking about branches and stages) and requires the recorded facts
# to win. When a fact is not recorded, the answer is an HONEST REFUSAL naming
# what is missing (behaviour D8), never a heuristic.
#
# THE PR RESOLUTION WINNER (spike LEG B, real gh 2.96.0):
#   `gh issue view <n> --json closedByPullRequestsReferences` — exact (it excludes
#   a PR that merely MENTIONS the issue), self-filters to LIVE PRs, returns the
#   same `url` open_pr() records as prUrl, and is a live GraphQL read rather than
#   the search index. `gh pr list --search` is REJECTED: observably stale in BOTH
#   directions, and adopt runs the instant a PR opens — when that index is least
#   trustworthy. Behaviours R1-R5 pin the winner, the decoy, the anchored
#   fallback, and that --search is never reached for.
#
# Everything here is stubbed — `gh` is an argv-recording script modelling the
# semantics the spike recorded. No network, no model, no real forge.
#
# Usage: bash tests/lcars-adopt.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_ADOPT_SCRIPT:-$REPO_ROOT/skills/lcars-adopt/adopt.sh}"
ADAPTER="${LCARS_HOST_ADAPTER:-$REPO_ROOT/skills/lcars-run/host-adapter.sh}"
APPROVE_SCRIPT="$REPO_ROOT/skills/lcars-approve/approve.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260908-042"

# Never let a stub-remote fetch reach the network or prompt for credentials.
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1

# ==========================================================================
# The stub `gh`.
#
# It records every call to $GH_LOG and serves a FIXTURE DIRECTORY ($GH_FIX)
# modelling one repo's issues and PRs:
#
#   issue-<n>.body     the issue body            (absent ⇒ empty)
#   issue-<n>.title    the issue title
#   issue-<n>.labels   label names, one per line
#   closes-<n>         what closedByPullRequestsReferences returns for issue n,
#                      as `<number><TAB><url>` lines — i.e. GitHub's OWN answer
#                      to "which PRs would close this issue", which is why the
#                      DECOY never appears in it (spike B.1).
#   prs.list           OPEN PRs as `<number><TAB><url><TAB><body-file>` — the
#                      list endpoint the FALLBACK scans.
#
# Env switches:
#   GH_OLD=1        the winner field is unknown to this gh — rc=1 with
#                   `Unknown JSON field:` (spike failure mode 10).
#   GH_ASSIGN_STATE a file of current assignee logins (leg A's model).
#   GH_WHOAMI       the login `gh api … user` echoes.
#
# THE FALLBACK IS EMULATED FAITHFULLY: the stub extracts the REGEX out of the
# production code's own --jq `test("…")` filter and applies it per line with
# grep -E. So an UNANCHORED production filter really does match `Closes #21`
# when it asked for `#2`, and behaviour R4 really does catch it (failure mode
# 14) — the stub does not do the anchoring on the production code's behalf.
# ==========================================================================
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"

fix="${GH_FIX:-}"

# --- the JSON field this call asks for, and the --jq filter (if any) --------
jsonf=""; jqf=""; args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --json) i=$((i+1)); jsonf="${args[$i]:-}" ;;
    --jq)   i=$((i+1)); jqf="${args[$i]:-}" ;;
  esac
  i=$((i+1))
done

if [ "${1:-}" = "api" ]; then
  for a in "$@"; do
    if [ "$a" = "user" ]; then
      [ -n "${GH_WHOAMI:-}" ] && echo "$GH_WHOAMI"
      exit "${GH_API_RC:-0}"
    fi
  done
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  n="${3:-}"
  case "$jsonf" in
    body)      [ -f "$fix/issue-$n.body" ]   && cat "$fix/issue-$n.body";   exit 0 ;;
    title)     [ -f "$fix/issue-$n.title" ]  && cat "$fix/issue-$n.title";  exit 0 ;;
    labels)    [ -f "$fix/issue-$n.labels" ] && cat "$fix/issue-$n.labels"; exit 0 ;;
    assignees) st="${GH_ASSIGN_STATE:-}"; [ -n "$st" ] && [ -f "$st" ] && cat "$st"; exit 0 ;;
    closedByPullRequestsReferences)
      if [ "${GH_OLD:-0}" = "1" ]; then
        echo 'Unknown JSON field: "closedByPullRequestsReferences"' >&2
        echo 'Available fields:' >&2
        echo '  assignees' >&2
        exit 1
      fi
      if [ ! -f "$fix/issue-$n.body" ] && [ ! -f "$fix/closes-$n" ]; then
        echo 'GraphQL: Could not resolve to an issue or pull request with the number of '"$n"'. (repository.issue)' >&2
        exit 1
      fi
      [ -f "$fix/closes-$n" ] && cat "$fix/closes-$n"
      exit 0 ;;
  esac
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
  n="${3:-}"; add=""; rem=""
  shift 3 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --add-assignee)    add="${2:-}"; shift 2 ;;
      --remove-assignee) rem="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  st="${GH_ASSIGN_STATE:-}"
  if [ -n "$add" ] && [ -n "$st" ]; then
    grep -qx -- "$add" "$st" 2>/dev/null || echo "$add" >>"$st"
  fi
  if [ -n "$rem" ] && [ -n "$st" ] && [ -f "$st" ]; then
    grep -vx -- "$rem" "$st" >"$st.tmp" 2>/dev/null; mv "$st.tmp" "$st"
  fi
  echo "https://github.com/acme/repo/issues/$n"
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  # The FALLBACK's list endpoint. Apply the production filter's OWN regex.
  re="$(printf '%s' "$jqf" | sed -n 's/.*test("\(.*\)")).*/\1/p')"
  re="${re#(?m)}"
  [ -n "$re" ] || exit 0
  [ -f "$fix/prs.list" ] || exit 0
  while IFS="$(printf '\t')" read -r pn purl pbody; do
    [ -n "$pn" ] || continue
    if grep -Eq "$re" "$fix/$pbody" 2>/dev/null; then
      printf '%s\t%s\n' "$pn" "$purl"
    fi
  done <"$fix/prs.list"
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then exit 0; fi
exit 0
EOF
  chmod +x "$1"
}

# --------------------------------------------------------------------------
# Fixtures.
# --------------------------------------------------------------------------
TAB="$(printf '\t')"

envelope() { # id branch base type engine parentIssue attachments [parked]
  local parked=""
  [ "${8:-}" = "true" ] && parked=',"parked":true'
  printf '<!-- lcars:handoff v1 {"id":"%s","branch":"%s","base":"%s","type":"%s","engine":"%s","parentIssue":%s,"attachments":%s%s} -->' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$parked"
}

# A body shaped exactly like the S188 composer's: the PRD, then a blank line,
# then the envelope ALONE on the last line.
mk_body() { # <out-file> <prd-text> <envelope>
  { printf '%s\n' "$2"; printf '\n%s\n' "$3"; } >"$1"
}

PRD_TEXT='# Mission: Add dark mode
**Type:** feature
**Goal:** Let users switch to a dark colour scheme.
**Acceptance Criteria:**
- A toggle persists the choice'

# new_fixture <dir> — an empty fixture dir.
new_fixture() { mkdir -p "$1"; printf '%s' "$1"; }

# A git repo with a REAL bare origin, so branch fetches are exercised for real
# without a network. Echoes "<repo>\t<origin>".
new_repo() {
  local origin repo
  origin="$(mktemp -d "$TMPROOT/origin.XXXX")"
  # `-b main` on the BARE repo too: without it the bare HEAD points at an unborn
  # `master`, a clone of it checks out nothing, and a branch cut there is an
  # ORPHAN — which silently makes every "is the base ahead?" question answer YES.
  git init --bare -q -b main "$origin" 2>/dev/null || git init --bare -q "$origin"
  repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  (
    cd "$repo" &&
    git init -q -b main &&
    git config user.email t@t && git config user.name t &&
    git commit -q --allow-empty -m init &&
    git remote add origin "$origin" &&
    git push -q origin main
  ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'CFG'
{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "created": "2026-05-30T00:00:00Z" }
CFG
  printf '%s\t%s' "$repo" "$origin"
}

# seed_branch <origin> <branch> — push a branch to the shared origin from a
# SEPARATE clone, so the adopting repo has no remote-tracking ref for it until
# adopt fetches one. That is what makes the fetch assertion mean something.
seed_branch() { # <origin> <branch>
  local w; w="$(mktemp -d "$TMPROOT/seed.XXXX")"
  (
    cd "$w" &&
    git clone -q -b main "$1" . &&
    git config user.email t@t && git config user.name t &&
    git checkout -q -b "$2" &&
    printf 'export const theme = "dark";\n' >theme.js &&
    git add -A && git commit -q -m "work" &&
    git push -q origin "$2"
  ) >/dev/null 2>&1
}

mdir_of()  { printf '%s/.git/lcars/missions/%s' "$1" "$2"; }
state_of() { printf '%s/.git/lcars/missions/%s/state.json' "$1" "$2"; }

# --------------------------------------------------------------------------
# THE PARSE GUARD (S189 fix round 1, defect 1 — the regression this suite owes
# the captain).
#
# This suite had 100 green checks and ZERO JSON PARSES, so it asserted on TEXT
# and corrupt JSON sailed straight through it — including its own idempotency
# check. adopt's refresh path was writing an INVALID object (a trailing comma:
# the field writer deleted `base`, the LAST field of every state.json, and
# re-inserted it at the top with a hard-coded comma, so the previously-second-
# to-last line kept its comma and became the last). `grep '"stage"'` is happy
# with that. `lcars status`, being sed-based, was happy with it. The viewscreen
# board is NOT: web/lcars_serve/local_adapter._card runs a real JSON parser, so
# the card was DROPPED and the mission silently VANISHED from the captain's
# primary surface — on the ORIGINAL laptop as well as the second one.
#
# So state.json is PARSED after every state-mutating path below, and the fields
# that matter are read back THROUGH the parser rather than grepped. A text
# assertion cannot see this class of defect, and neither can a human re-reading
# the file by eye.
json_ok()   { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }
json_type() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.stdout.write(type(d.get(sys.argv[2])).__name__)' "$1" "$2" 2>/dev/null; }
json_get()  { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); sys.stdout.write("" if v is None else str(v))' "$1" "$2" 2>/dev/null; }
json_has()  { python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)' "$1" "$2" 2>/dev/null; }

command -v python3 >/dev/null 2>&1 || {
  echo "  python3 is REQUIRED by this suite — it is the only assertion that can see"
  echo "  invalid JSON, which is the defect this suite exists to guard."
  exit 1
}

# ==========================================================================
echo "lcars adopt (S189: rebuild a mission at the ends, from the issue alone)"

[ -f "$SCRIPT" ]  || { echo "  script under test not found at $SCRIPT"; bad "adopt.sh exists"; }
[ -f "$ADAPTER" ] || { echo "  host adapter not found at $ADAPTER"; exit 1; }

GH="$TMPROOT/gh"; make_gh_stub "$GH"
export GH_LOG="$TMPROOT/gh.log"

# ==========================================================================
echo
echo "host-adapter — the READ ops adopt needs"
# ==========================================================================

FIX="$(new_fixture "$TMPROOT/fix")"
export GH_FIX="$FIX"
mk_body "$FIX/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIX/issue-42.title"
printf 'lcars:mission\nlcars:verify\nfeature\n' >"$FIX/issue-42.labels"
printf '77%shttps://github.com/acme/repo/pull/77\n' "$TAB" >"$FIX/closes-42"

# The DECOY: an OPEN PR that MENTIONS #42 and closes nothing.
printf 'Related to #42 but carries no Closes directive.\n' >"$FIX/pr-88.body"
# The real PR — the LCARS-written directive, anchored at the end of the body.
printf '## Summary\n\nMission work.\nCloses #42\n' >"$FIX/pr-77.body"
# A PR that closes #421 — the unanchored-match trap (failure mode 14).
printf 'Other mission.\nCloses #421\n' >"$FIX/pr-99.body"
{
  printf '77%shttps://github.com/acme/repo/pull/77%spr-77.body\n' "$TAB" "$TAB"
  printf '88%shttps://github.com/acme/repo/pull/88%spr-88.body\n' "$TAB" "$TAB"
  printf '99%shttps://github.com/acme/repo/pull/99%spr-99.body\n' "$TAB" "$TAB"
} >"$FIX/prs.list"

: >"$GH_LOG"
out="$(LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-body 42 2>/dev/null)"
check "H1. issue-body echoes the issue's body verbatim" \
  "printf '%s' \"\$out\" | grep -q 'Add dark mode' && printf '%s' \"\$out\" | grep -q 'lcars:handoff'"
check "H1. issue-body asks gh for the body field" \
  "grep -q 'issue view 42 --json body' '$GH_LOG'"

out="$(LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-title 42 2>/dev/null)"
check "H2. issue-title echoes the title" "[ \"\$out\" = 'Add dark mode' ]"

out="$(LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-labels 42 2>/dev/null)"
check "H3. issue-labels echoes one label per line" \
  "printf '%s\n' \"\$out\" | grep -qx 'lcars:verify' && printf '%s\n' \"\$out\" | grep -qx 'lcars:mission'"

# --- R1: the WINNER, and its exact argv -----------------------------------
: >"$GH_LOG"
rc=0
out="$(LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-closing-prs 42 2>/dev/null)" || rc=$?
check "R1. issue-closing-prs uses the spike WINNER (closedByPullRequestsReferences)" \
  "grep -q 'issue view 42 --json closedByPullRequestsReferences' '$GH_LOG'"
check "R1. issue-closing-prs echoes <number><TAB><url>" \
  "printf '%s' \"\$out\" | grep -q '^77${TAB}https://github.com/acme/repo/pull/77\$'"
check "R1. issue-closing-prs returns 0 on the happy path" "[ '$rc' -eq 0 ]"

# --- R2: gh pr list --search is REJECTED, in both paths -------------------
check "R2. the winner NEVER reaches for the (stale) search index" \
  "! grep -q -- '--search' '$GH_LOG'"

# --- R3: the DECOY is not the mission's PR --------------------------------
check "R3. a PR that merely MENTIONS the issue is NOT resolved as its PR" \
  "! printf '%s' \"\$out\" | grep -q 'pull/88'"

# --- R4: the FALLBACK, detected (not version-gated) on `Unknown JSON field:`
: >"$GH_LOG"
rc=0
out="$(GH_OLD=1 LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-closing-prs 42 2>/dev/null)" || rc=$?
check "R4. an old gh (rc=1, 'Unknown JSON field:') triggers the FALLBACK, not a failure" \
  "[ '$rc' -eq 0 ]"
check "R4. the fallback scans the OPEN PR LIST endpoint (no index lag)" \
  "grep -q 'pr list --state open' '$GH_LOG'"
check "R4. the fallback NEVER uses --search" "! grep -q -- '--search' '$GH_LOG'"
check "R4. the fallback finds the real PR" \
  "printf '%s' \"\$out\" | grep -q '^77${TAB}https://github.com/acme/repo/pull/77\$'"
check "R4. the fallback excludes the DECOY (mentions, does not close)" \
  "! printf '%s' \"\$out\" | grep -q 'pull/88'"
check "R4. the fallback ANCHORS the directive — 'Closes #421' is NOT a match for #42" \
  "! printf '%s' \"\$out\" | grep -q 'pull/99'"

# --- R5: no PR at all → empty at rc=0 (failure mode 11) -------------------
mk_body "$FIX/issue-7.body" "$PRD_TEXT" "$(envelope lcars-x lcars/x main feature claude null 0)"
rc=0
out="$(LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-closing-prs 7 2>/dev/null)" || rc=$?
check "R5. no closing PR ⇒ EMPTY output at rc=0 (never an error)" \
  "[ -z \"\$out\" ] && [ '$rc' -eq 0 ]"

# ==========================================================================
echo
echo "adopt at ALIGN — claim, rebuild, fetch"
# ==========================================================================

# --- Behaviour 4 -----------------------------------------------------------
IFS="$TAB" read -r repoA originA <<<"$(new_repo)"
FIXA="$(new_fixture "$TMPROOT/fixA")"
mk_body "$FIXA/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXA/issue-42.title"
printf 'lcars:mission\nlcars:align\nfeature\n' >"$FIXA/issue-42.labels"
seed_branch "$originA" "lcars/$MID"

ASSIGN_A="$TMPROOT/assignA.txt"; : >"$ASSIGN_A"
: >"$GH_LOG"
rcA=0
( cd "$repoA" && GH_FIX="$FIXA" GH_ASSIGN_STATE="$ASSIGN_A" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcA=$?
mA="$(mdir_of "$repoA" "$MID")"; sA="$(state_of "$repoA" "$MID")"

check "4. adopt at align exits 0" "[ '$rcA' -eq 0 ]"
check "4. the mission dir is the ENVELOPE'S id — never a minted one" "[ -d '$mA' ]"
check "4. exactly ONE mission dir exists (no minted sibling)" \
  "[ \"\$(ls -1 '$repoA/.git/lcars/missions' | wc -l | tr -d ' ')\" = '1' ]"
check "4. prd.md is rebuilt from the issue body" \
  "[ -f '$mA/prd.md' ] && grep -q 'Add dark mode' '$mA/prd.md'"
check "4. prd.md does NOT carry the machine envelope (it is stripped)" \
  "! grep -q 'lcars:handoff' '$mA/prd.md'"
check "4. state.json reuses the envelope id" "grep -q '\"id\": *\"$MID\"' '$sA'"
check "4. state.json takes branch from the envelope" "grep -q '\"branch\": *\"lcars/$MID\"' '$sA'"
check "4. state.json takes base from the envelope" "grep -q '\"base\": *\"main\"' '$sA'"
check "4. state.json takes type from the envelope" "grep -q '\"type\": *\"feature\"' '$sA'"
check "4. state.json takes the engine from the envelope (workerBin)" \
  "grep -q '\"workerBin\": *\"claude\"' '$sA'"
check "4. state.json records the issue number" "grep -q '\"githubIssue\": *42' '$sA'"
check "4. STAGE comes from the lcars:<stage> LABEL" "grep -q '\"stage\": *\"align\"' '$sA'"
check "4. adopt CLAIMS the mission at align (assigns the captain)" \
  "grep -q 'issue edit 42 --add-assignee capt' '$GH_LOG'"
check "4. the claim really landed (read back)" "grep -qx capt '$ASSIGN_A'"
check "4. the branch on origin is FETCHED" \
  "( cd '$repoA' && git rev-parse --verify -q 'refs/remotes/origin/lcars/$MID' ) >/dev/null"
check "4. a local branch is created so approve can push it" \
  "( cd '$repoA' && git rev-parse --verify -q 'refs/heads/lcars/$MID' ) >/dev/null"
check "4. the readout names the mission and the stage" \
  "grep -q '$MID' '$repoA/out.txt' && grep -qi 'align' '$repoA/out.txt'"
# THE PARSE. A fresh adopt writes state.json from scratch — prove it is real
# JSON, and read the recorded facts back THROUGH the parser, not through grep.
check "4. state.json PARSES as JSON (a fresh adopt)" "json_ok '$sA'"
check "4. the parser sees the envelope id" "[ \"\$(json_get '$sA' id)\" = '$MID' ]"
check "4. the parser sees stage=align (from the label)" \
  "[ \"\$(json_get '$sA' stage)\" = 'align' ]"
check "4. githubIssue is a JSON NUMBER, as file.sh writes it" \
  "[ \"\$(json_type '$sA' githubIssue)\" = 'int' ]"

# --- a branch that does NOT exist on origin yet: no crash, an honest note ---
IFS="$TAB" read -r repoAB originAB <<<"$(new_repo)"
FIXAB="$(new_fixture "$TMPROOT/fixAB")"
mk_body "$FIXAB/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXAB/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXAB/issue-42.labels"
rcAB=0
( cd "$repoAB" && GH_FIX="$FIXAB" GH_ASSIGN_STATE="$TMPROOT/assignAB.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcAB=$?
check "4b. a mission whose branch is not on origin yet still adopts (exit 0)" "[ '$rcAB' -eq 0 ]"
check "4b. the mission is still rebuilt" "[ -f '$(state_of "$repoAB" "$MID")' ]"
check "4b. the readout says the branch is not on the remote yet" \
  "grep -qi 'branch' '$repoAB/out.txt'"
check "4b. state.json PARSES even when the branch was never fetched" \
  "json_ok '$(state_of "$repoAB" "$MID")'"

# ==========================================================================
echo
echo "adopt at VERIFY — join, resolve the PR, hand over a working approve"
# ==========================================================================

# --- Behaviour 5 -----------------------------------------------------------
IFS="$TAB" read -r repoV originV <<<"$(new_repo)"
FIXV="$(new_fixture "$TMPROOT/fixV")"
mk_body "$FIXV/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXV/issue-42.title"
printf 'lcars:mission\nlcars:verify\nfeature\n' >"$FIXV/issue-42.labels"
printf '77%shttps://github.com/acme/repo/pull/77\n' "$TAB" >"$FIXV/closes-42"
cp "$FIX/prs.list" "$FIXV/prs.list"; cp "$FIX"/pr-*.body "$FIXV/" 2>/dev/null
seed_branch "$originV" "lcars/$MID"

ASSIGN_V="$TMPROOT/assignV.txt"; : >"$ASSIGN_V"     # UNASSIGNED — a bare look
: >"$GH_LOG"
rcV=0
( cd "$repoV" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_V" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcV=$?
mV="$(mdir_of "$repoV" "$MID")"; sV="$(state_of "$repoV" "$MID")"

check "5. adopt at verify exits 0" "[ '$rcV' -eq 0 ]"
check "5. state is rebuilt at stage verify (from the label)" "grep -q '\"stage\": *\"verify\"' '$sV'"
check "5. the open PR is RESOLVED and persisted as prUrl" \
  "grep -q '\"prUrl\": *\"https://github.com/acme/repo/pull/77\"' '$sV'"
# DEFECT 2 (S189 fix round 1). prNumber is a STRING, matching the ONE existing
# writer — pr-lib.sh, which run.sh's Verify auto-open goes through. adopt first
# wrote it as a bare NUMBER, so the same PR carried a different JSON TYPE on the
# two laptops and their state.json files were not interchangeable to a real JSON
# reader. Interchangeability is the contract this whole verb delivers, so adopt
# matches the incumbent writer rather than being unilaterally more correct in
# one of two. (Upgrading BOTH writers to a number together is ledgered.)
check "5. the PR NUMBER is persisted too" \
  "grep -q '\"prNumber\": *\"77\"' '$sV'"
check "5. prNumber is a STRING — the same JSON type pr-lib.sh writes" \
  "[ \"\$(json_type '$sV' prNumber)\" = 'str' ] && [ \"\$(json_get '$sV' prNumber)\" = '77' ]"
check "5. the DECOY PR is never recorded" "! grep -q 'pull/88' '$sV'"
check "5. the branch is fetched at verify too" \
  "( cd '$repoV' && git rev-parse --verify -q 'refs/heads/lcars/$MID' ) >/dev/null"
check "5. the readout prints the PR url" "grep -q 'pull/77' '$repoV/out.txt'"
check "5. state.json PARSES after a VERIFY adopt records the PR fields" "json_ok '$sV'"
check "5. the parser sees the resolved PR url" \
  "[ \"\$(json_get '$sV' prUrl)\" = 'https://github.com/acme/repo/pull/77' ]"
check "5. the parser sees the in-review sub-state" \
  "[ \"\$(json_get '$sV' review)\" = 'open' ]"

# ...and approve now works immediately, with no other command in between.
#
# approve's pre-merge reconcile is stubbed exactly as tests/lcars-approve.test.sh
# stubs it (LCARS_RUN_SCRIPT): this suite is about what ADOPT handed approve, and
# the stub guarantees no run.sh subprocess — and so no worker, and so no spend —
# can be reached from here. Everything else in approve is the real script.
cat >"$repoV/recon.sh" <<'RECON'
#!/usr/bin/env bash
exit 0
RECON
chmod +x "$repoV/recon.sh"
: >"$GH_LOG"
rcAP=0
( cd "$repoV" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_V" LCARS_GH_USER=capt \
    LCARS_RUN_SCRIPT="$repoV/recon.sh" \
    LCARS_GH_BIN="$GH" bash "$APPROVE_SCRIPT" --mission "$MID" >approve.txt 2>&1 ) || rcAP=$?
check "5. approve runs straight after adopt (exit 0)" "[ '$rcAP' -eq 0 ]"
# approve's selector: with prNumber recorded in pr-lib.sh's STRING shape, its
# bare-token reader (approve.sh json_raw) returns "" and it falls back to
# `--head <branch>` — the same fallback the driving laptop takes today, which
# GitHub resolves to this mission's one open PR. What matters is that approve
# merges THIS mission's PR and never the decoy: pin the selector exactly.
check "5. approve merges the PR adopt resolved (by the mission's own branch)" \
  "grep -q 'pr merge lcars/$MID ' '$GH_LOG'"
check "5. approve never reaches for the DECOY PR" "! grep -q 'pr merge 88' '$GH_LOG'"
check "5. approve flips the adopted mission to done" "grep -q '\"stage\": *\"done\"' '$sV'"
check "5. state.json still PARSES after approve has written to it" "json_ok '$sV'"
check "5. the parser agrees the mission is done" \
  "[ \"\$(json_get '$sV' stage)\" = 'done' ]"

# --- an UNOWNED verify LOOK works, but ACTING without ownership refuses -----
IFS="$TAB" read -r repoL originL <<<"$(new_repo)"
FIXL="$(new_fixture "$TMPROOT/fixL")"
mk_body "$FIXL/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXL/issue-42.title"
printf 'lcars:mission\nlcars:verify\n' >"$FIXL/issue-42.labels"
printf '77%shttps://github.com/acme/repo/pull/77\n' "$TAB" >"$FIXL/closes-42"
seed_branch "$originL" "lcars/$MID"
ASSIGN_L="$TMPROOT/assignL.txt"; printf 'someone-else\n' >"$ASSIGN_L"
rcL=0
( cd "$repoL" && GH_FIX="$FIXL" GH_ASSIGN_STATE="$ASSIGN_L" GH_LOG="$repoL/gh.log" \
    LCARS_GH_USER=capt LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcL=$?
check "5b. a mission owned by SOMEONE ELSE can still be adopted to LOOK at" "[ '$rcL' -eq 0 ]"
check "5b. adopt does NOT steal it (no assign call at all)" \
  "! grep -q -- '--add-assignee' '$repoL/gh.log'"
check "5b. the assignee on GitHub is untouched" "grep -qx 'someone-else' '$ASSIGN_L'"
check "5b. adopt says who holds it" "grep -q 'someone-else' '$repoL/out.txt'"
check "5b. the state is still rebuilt (reads are never blocked)" \
  "[ -f '$(state_of "$repoL" "$MID")' ]"
check "5b. and it PARSES (an unowned LOOK still writes valid JSON)" \
  "json_ok '$(state_of "$repoL" "$MID")'"
rcLA=0
( cd "$repoL" && GH_FIX="$FIXL" GH_ASSIGN_STATE="$ASSIGN_L" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$APPROVE_SCRIPT" --mission "$MID" >approve.txt 2>&1 ) || rcLA=$?
check "5b. approve on a mission owned by someone else REFUSES" "[ '$rcLA' -ne 0 ]"
check "5b. the refusal names the owner and the remedy" \
  "grep -q 'someone-else' '$repoL/approve.txt' && grep -qi 'reassign' '$repoL/approve.txt'"
check "5b. the mission is NOT flipped to done" \
  "! grep -q '\"stage\": *\"done\"' '$(state_of "$repoL" "$MID")'"

# ==========================================================================
echo
echo "the v1 BOUNDARY, idempotency, and honest refusals"
# ==========================================================================

# --- Behaviour 6: mid-pipeline is refused, honestly ------------------------
IFS="$TAB" read -r repoM originM <<<"$(new_repo)"
FIXM="$(new_fixture "$TMPROOT/fixM")"
mk_body "$FIXM/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXM/issue-42.title"
printf 'lcars:mission\nlcars:implement\n' >"$FIXM/issue-42.labels"
rcM=0
( cd "$repoM" && GH_FIX="$FIXM" GH_ASSIGN_STATE="$TMPROOT/assignM.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcM=$?
check "6. adopt mid-pipeline REFUSES (non-zero)" "[ '$rcM' -ne 0 ]"
check "6. the refusal names the actual stage" "grep -q 'implement' '$repoM/out.txt'"
check "6. the refusal names the v1 boundary (Align and Verify)" \
  "grep -qi 'align' '$repoM/out.txt' && grep -qi 'verify' '$repoM/out.txt'"
check "6. NOTHING is left on disk after a mid-pipeline refusal" \
  "[ -z \"\$(ls -A '$repoM/.git/lcars/missions')\" ]"
check "6. a refused adopt never claims the mission" \
  "[ ! -s '$TMPROOT/assignM.txt' ]"

# --- Behaviour 7: idempotent — a SECOND adopt refreshes, never duplicates ---
IFS="$TAB" read -r repoI originI <<<"$(new_repo)"
FIXI="$(new_fixture "$TMPROOT/fixI")"
mk_body "$FIXI/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXI/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXI/issue-42.labels"
( cd "$repoI" && GH_FIX="$FIXI" GH_ASSIGN_STATE="$TMPROOT/assignI.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out1.txt 2>&1 )
mI="$(mdir_of "$repoI" "$MID")"; sI="$(state_of "$repoI" "$MID")"
check "7. state.json PARSES after the FIRST adopt" "json_ok '$sI'"
# A local-only artifact the second laptop must NOT lose.
printf 'the captain said: make it teal\n' >"$mI/feedback.md"
created1="$(sed -n 's/.*"created"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$sI" | head -1)"
# The spec moved on GitHub (a re-grill refreshed the body — S188's transfer point).
mk_body "$FIXI/issue-42.body" "$PRD_TEXT
- AND it remembers the choice across devices" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
rcI=0
( cd "$repoI" && GH_FIX="$FIXI" GH_ASSIGN_STATE="$TMPROOT/assignI.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out2.txt 2>&1 ) || rcI=$?
check "7. re-adopting an already-local mission exits 0" "[ '$rcI' -eq 0 ]"
check "7. it REFRESHES rather than duplicates (still one mission dir)" \
  "[ \"\$(ls -1 '$repoI/.git/lcars/missions' | wc -l | tr -d ' ')\" = '1' ]"
check "7. the refreshed prd.md carries the NEW spec" \
  "grep -q 'across devices' '$mI/prd.md'"
check "7. state.json is still valid single-keyed JSON (no duplicated keys)" \
  "[ \"\$(grep -c '\"stage\"' '$sI')\" = '1' ] && [ \"\$(grep -c '\"branch\"' '$sI')\" = '1' ]"
check "7. local-only artifacts are PRESERVED across a refresh" \
  "[ -f '$mI/feedback.md' ] && grep -q teal '$mI/feedback.md'"
created2="$(sed -n 's/.*"created"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$sI" | head -1)"
check "7. the mission's created stamp is not rewritten by a refresh" \
  "[ -n '$created1' ] && [ '$created1' = '$created2' ]"

# THE CURE'S OWN REGRESSION. The refresh path rewrites `base` — the LAST field
# of every state.json — and the inherited field writer left a TRAILING COMMA
# doing it. Every text assertion above passed while this file was unparseable
# and the mission had vanished from the board. Parse it.
check "7. state.json PARSES after the SECOND adopt (the REFRESH path)" "json_ok '$sI'"
check "7. and the parser sees the refreshed base, the field that broke it" \
  "[ \"\$(json_get '$sI' base)\" = 'main' ]"
check "7. the LAST field carries no trailing comma (the exact corruption)" \
  "! tail -2 '$sI' | head -1 | grep -q ',[[:space:]]*\$'"

# A THIRD adopt: the refresh must be STABLE, not merely valid once. A cure that
# re-derived the commas but re-ordered or re-doubled a field would drift here.
before3="$(cat "$sI")"
rcI3=0
( cd "$repoI" && GH_FIX="$FIXI" GH_ASSIGN_STATE="$TMPROOT/assignI.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out3.txt 2>&1 ) || rcI3=$?
check "7. a THIRD adopt exits 0" "[ '$rcI3' -eq 0 ]"
check "7. state.json PARSES after the THIRD adopt" "json_ok '$sI'"
check "7. the third adopt is byte-stable (a refresh converges, it does not drift)" \
  "[ \"\$before3\" = \"\$(cat '$sI')\" ]"
check "7. local-only artifacts survive three adopts" \
  "[ -f '$mI/feedback.md' ] && grep -q teal '$mI/feedback.md'"

# --- a REFRESH that follows the mission BACK to align drops the stale PR -----
# `lcars feedback` closes the PR when it bounces a mission, and Verify opens a
# fresh one on the way back — so a prUrl left on this laptop from before the
# bounce is stale by the LABEL's own account. The stage is the recorded fact.
IFS="$TAB" read -r repoB2 originB2 <<<"$(new_repo)"
FIXB2="$(new_fixture "$TMPROOT/fixB2")"
mk_body "$FIXB2/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXB2/issue-42.title"
printf 'lcars:mission\nlcars:verify\n' >"$FIXB2/issue-42.labels"
printf '77%shttps://github.com/acme/repo/pull/77\n' "$TAB" >"$FIXB2/closes-42"
( cd "$repoB2" && GH_FIX="$FIXB2" GH_ASSIGN_STATE="$TMPROOT/assignB2.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out1.txt 2>&1 )
sB2="$(state_of "$repoB2" "$MID")"
check "7b. the verify adopt recorded a PR to begin with" "grep -q 'prUrl' '$sB2'"
check "7b. state.json PARSES after the verify adopt" "json_ok '$sB2'"
printf 'lcars:mission\nlcars:align\n' >"$FIXB2/issue-42.labels"    # bounced on GitHub
( cd "$repoB2" && GH_FIX="$FIXB2" GH_ASSIGN_STATE="$TMPROOT/assignB2.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out2.txt 2>&1 )
check "7b. a refresh that lands at align drops the now-stale prUrl/prNumber/review" \
  "! grep -q 'prUrl' '$sB2' && ! grep -q 'prNumber' '$sB2' && ! grep -q '\"review\"' '$sB2'"
check "7b. and the mission really is back at align" "grep -q '\"stage\": *\"align\"' '$sB2'"
# The align-refresh DELETES three fields and rewrites `base`. Deleting a field
# moves the comma just as rewriting one does, so this path gets the parser too.
check "7b. state.json PARSES after the align refresh drops prUrl/prNumber/review" \
  "json_ok '$sB2'"
check "7b. the parser confirms the PR fields are GONE, not merely un-greppable" \
  "! json_has '$sB2' prUrl && ! json_has '$sB2' prNumber && ! json_has '$sB2' review"
check "7b. the parser sees the mission back at align" \
  "[ \"\$(json_get '$sB2' stage)\" = 'align' ]"

# --- 7c: a refresh over a state.json written by `lcars file` ---------------
# The suite's other refresh cases refresh a state adopt itself wrote. THIS one
# starts from the shape file.sh's write_state emits on the ORIGINAL laptop —
# `base` last, plus the local-only fields a driven mission accumulates
# (modelOverride, baseSha, attachments). That is the file the captain actually
# has when he re-adopts his own mission, and it is the exact case the trailing
# comma corrupted.
IFS="$TAB" read -r repoLO originLO <<<"$(new_repo)"
FIXLO="$(new_fixture "$TMPROOT/fixLO")"
mk_body "$FIXLO/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode (renamed on GitHub)\n' >"$FIXLO/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXLO/issue-42.labels"
mkdir -p "$repoLO/.git/lcars/missions/$MID"
cat >"$repoLO/.git/lcars/missions/$MID/state.json" <<'LOCAL'
{
  "id": "lcars-20260908-042",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "align",
  "created": "2026-09-01T00:00:00Z",
  "model": "claude-sonnet",
  "modelOverride": { "scope": "mission", "tier": "opus" },
  "attachments": ["attachments/attachment-01.png"],
  "baseSha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  "githubIssue": 42,
  "branch": "lcars/lcars-20260908-042",
  "base": "main"
}
LOCAL
sLO="$(state_of "$repoLO" "$MID")"
check "7c. the seeded local state is valid to begin with (the test's own premise)" \
  "json_ok '$sLO'"
rcLO=0
( cd "$repoLO" && GH_FIX="$FIXLO" GH_ASSIGN_STATE="$TMPROOT/assignLO.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcLO=$?
check "7c. re-adopting over a file.sh-shaped state exits 0" "[ '$rcLO' -eq 0 ]"
check "7c. it is STILL VALID JSON after base (the LAST field) is rewritten" \
  "json_ok '$sLO'"
check "7c. the refreshed title came from GitHub" \
  "[ \"\$(json_get '$sLO' title)\" = 'Add dark mode (renamed on GitHub)' ]"
check "7c. the LOCAL-ONLY baseSha survives the refresh" \
  "[ \"\$(json_get '$sLO' baseSha)\" = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' ]"
check "7c. the LOCAL-ONLY modelOverride survives, still a real nested object" \
  "[ \"\$(json_type '$sLO' modelOverride)\" = 'dict' ] && json_ok '$sLO'"
check "7c. the LOCAL-ONLY attachments list survives, still a real list" \
  "[ \"\$(json_type '$sLO' attachments)\" = 'list' ]"
check "7c. the created stamp is still the ORIGINAL laptop's" \
  "[ \"\$(json_get '$sLO' created)\" = '2026-09-01T00:00:00Z' ]"

# And a state.json a PREVIOUS (broken) adopt already corrupted is REPAIRED
# rather than compounded — the captain does not have to delete anything by hand.
IFS="$TAB" read -r repoCR originCR <<<"$(new_repo)"
FIXCR="$(new_fixture "$TMPROOT/fixCR")"
mk_body "$FIXCR/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXCR/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXCR/issue-42.labels"
mkdir -p "$repoCR/.git/lcars/missions/$MID"
cat >"$repoCR/.git/lcars/missions/$MID/state.json" <<'BROKEN'
{
  "base": "main",
  "id": "lcars-20260908-042",
  "title": "Add dark mode",
  "stage": "align",
  "created": "2026-09-01T00:00:00Z",
  "githubIssue": 42,
  "branch": "lcars/lcars-20260908-042",
}
BROKEN
sCR="$(state_of "$repoCR" "$MID")"
check "7d. the seeded state really IS the corruption (invalid JSON)" "! json_ok '$sCR'"
( cd "$repoCR" && GH_FIX="$FIXCR" GH_ASSIGN_STATE="$TMPROOT/assignCR.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 )
check "7d. adopting over an already-corrupted state REPAIRS it" "json_ok '$sCR'"
check "7d. and the repaired object keeps the recorded facts" \
  "[ \"\$(json_get '$sCR' id)\" = '$MID' ] && [ \"\$(json_get '$sCR' base)\" = 'main' ]"

# --- Behaviour 8: an envelope-less (pre-round) issue ------------------------
IFS="$TAB" read -r repoE originE <<<"$(new_repo)"
FIXE="$(new_fixture "$TMPROOT/fixE")"
printf '%s\n' "$PRD_TEXT" >"$FIXE/issue-42.body"      # NO envelope: a pre-round issue
printf 'Add dark mode\n' >"$FIXE/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXE/issue-42.labels"
rcE=0
( cd "$repoE" && GH_FIX="$FIXE" GH_ASSIGN_STATE="$TMPROOT/assignE.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcE=$?
check "8. an envelope-less issue is REFUSED, not crashed through" "[ '$rcE' -ne 0 ]"
check "8. the refusal explains WHAT IS MISSING (the handoff envelope)" \
  "grep -qi 'envelope\\|handoff' '$repoE/out.txt'"
check "8. the refusal names the issue it looked at" "grep -q '42' '$repoE/out.txt'"
check "8. the refusal is a plain message, not a bash error" \
  "! grep -qi 'unbound variable\\|no such file or directory\\|syntax error' '$repoE/out.txt'"
check "8. NO half-built mission dir is left behind" \
  "[ -z \"\$(ls -A '$repoE/.git/lcars/missions')\" ]"

# --- an envelope from a FUTURE schema: refuse, never guess ------------------
IFS="$TAB" read -r repoF2 originF2 <<<"$(new_repo)"
FIXF2="$(new_fixture "$TMPROOT/fixF2")"
mk_body "$FIXF2/issue-42.body" "$PRD_TEXT" \
  '<!-- lcars:handoff v2 {"id":"lcars-future","branch":"lcars/future"} -->'
printf 'Add dark mode\n' >"$FIXF2/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXF2/issue-42.labels"
rcF2=0
( cd "$repoF2" && GH_FIX="$FIXF2" GH_ASSIGN_STATE="$TMPROOT/assignF2.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcF2=$?
check "8b. a FUTURE envelope schema is refused rather than guessed at" "[ '$rcF2' -ne 0 ]"
check "8b. the refusal points at \`lcars update\`" \
  "grep -qi 'update' '$repoF2/out.txt'"
check "8b. no half-built mission dir" "[ -z \"\$(ls -A '$repoF2/.git/lcars/missions')\" ]"

# --- an issue with NO lcars stage label ------------------------------------
IFS="$TAB" read -r repoNS originNS <<<"$(new_repo)"
FIXNS="$(new_fixture "$TMPROOT/fixNS")"
mk_body "$FIXNS/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXNS/issue-42.title"
printf 'lcars:mission\nbug\n' >"$FIXNS/issue-42.labels"
rcNS=0
( cd "$repoNS" && GH_FIX="$FIXNS" GH_ASSIGN_STATE="$TMPROOT/assignNS.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcNS=$?
check "8c. an issue with no lcars:<stage> label is refused (the fact is not recorded)" \
  "[ '$rcNS' -ne 0 ]"
check "8c. the refusal says the stage label is missing" \
  "grep -qi 'stage' '$repoNS/out.txt' && grep -qi 'label' '$repoNS/out.txt'"
check "8c. no half-built mission dir" "[ -z \"\$(ls -A '$repoNS/.git/lcars/missions')\" ]"

# ==========================================================================
echo
echo "RULING 2 — the recorded facts win; the prose is never re-scanned"
# ==========================================================================

# --- P1: a PRD *about LCARS* that quotes a DECOY envelope and talks about
#     branches, stages and estimates. Every recorded fact must come from the
#     REAL (last) envelope and the LABEL — nothing from the prose.
IFS="$TAB" read -r repoP originP <<<"$(new_repo)"
FIXP="$(new_fixture "$TMPROOT/fixP")"
cat >"$FIXP/issue-42.body" <<EOF
# Mission: Document the handoff envelope

**Type:** chore
**Goal:** Explain the envelope LCARS appends to every issue body. It looks
like this, and carries the mission's branch and base:

    $(envelope lcars-DECOY-id lcars/DECOY-branch DECOY-base epic decoy-engine 999 7)

The mission's branch is \`lcars/from-the-prose\` and the stage is implement.

---

## Estimate
| Stage | Model |
|-------|-------|
| align | opus  |

$(envelope "$MID" "lcars/$MID" main feature claude null 0)
EOF
printf 'Document the handoff envelope\n' >"$FIXP/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXP/issue-42.labels"
rcP=0
( cd "$repoP" && GH_FIX="$FIXP" GH_ASSIGN_STATE="$TMPROOT/assignP.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcP=$?
sP="$(state_of "$repoP" "$MID")"
check "P1. a PRD quoting a DECOY envelope still adopts (exit 0)" "[ '$rcP' -eq 0 ]"
check "P1. the REAL (last) envelope's id wins over the quoted decoy" "[ -f '$sP' ]"
check "P1. no mission is built under the decoy id" \
  "[ ! -d '$repoP/.git/lcars/missions/lcars-DECOY-id' ]"
check "P1. the branch comes from the real envelope, not the prose" \
  "grep -q '\"branch\": *\"lcars/$MID\"' '$sP' && ! grep -q 'from-the-prose' '$sP'"
check "P1. the type comes from the real envelope, not the '**Type:**' line" \
  "grep -q '\"type\": *\"feature\"' '$sP'"
check "P1. the STAGE comes from the label, not the word 'implement' in the prose" \
  "grep -q '\"stage\": *\"align\"' '$sP'"
check "P1. the prose (including the '## Estimate' section) is kept VERBATIM in prd.md" \
  "grep -q 'Document the handoff envelope' '$repoP/.git/lcars/missions/$MID/prd.md' && \
   grep -q '## Estimate' '$repoP/.git/lcars/missions/$MID/prd.md'"
check "P1. only the REAL trailing envelope is stripped — the quoted one survives" \
  "grep -q 'lcars-DECOY-id' '$repoP/.git/lcars/missions/$MID/prd.md' && \
   ! grep -q '\"id\":\"$MID\"' '$repoP/.git/lcars/missions/$MID/prd.md'"

# --- P2: a CRLF body (GitHub stores web-edited bodies with \r\n) -----------
IFS="$TAB" read -r repoR originR <<<"$(new_repo)"
FIXR="$(new_fixture "$TMPROOT/fixR")"
mk_body "$TMPROOT/crlf.tmp" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
awk '{printf "%s\r\n", $0}' "$TMPROOT/crlf.tmp" >"$FIXR/issue-42.body"
printf 'Add dark mode\n' >"$FIXR/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXR/issue-42.labels"
rcR=0
( cd "$repoR" && GH_FIX="$FIXR" GH_ASSIGN_STATE="$TMPROOT/assignR.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcR=$?
check "P2. a CRLF issue body adopts cleanly" "[ '$rcR' -eq 0 ]"
check "P2. the envelope still parses out of a CRLF body" \
  "grep -q '\"branch\": *\"lcars/$MID\"' '$(state_of "$repoR" "$MID")'"
check "P2. prd.md carries no carriage returns" \
  "! grep -q \$'\\r' '$repoR/.git/lcars/missions/$MID/prd.md'"

# --- P3: a PARKED mission (envelope parked:true, label lcars:align) --------
IFS="$TAB" read -r repoPK originPK <<<"$(new_repo)"
FIXPK="$(new_fixture "$TMPROOT/fixPK")"
mk_body "$FIXPK/issue-42.body" 'Make the board show whose mission it is.

---

_◇ STANDBY — parked awaiting alignment._' \
  "$(envelope "$MID" "lcars/$MID" main '' '' null 0 true)"
printf 'Make the board show whose mission it is\n' >"$FIXPK/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXPK/issue-42.labels"
rcPK=0
( cd "$repoPK" && GH_FIX="$FIXPK" GH_ASSIGN_STATE="$TMPROOT/assignPK.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcPK=$?
mPK="$(mdir_of "$repoPK" "$MID")"
check "P3. a PARKED mission adopts at align" "[ '$rcPK' -eq 0 ]"
check "P3. a parked mission rebuilds idea.md, NOT prd.md (no PRD exists yet)" \
  "[ -f '$mPK/idea.md' ] && [ ! -f '$mPK/prd.md' ]"
check "P3. state.json carries prdPending" "grep -q '\"prdPending\": *true' '$(state_of "$repoPK" "$MID")'"
check "P3. an empty envelope type emits NO type key (byte-shape of a parked state)" \
  "! grep -q '\"type\"' '$(state_of "$repoPK" "$MID")'"
check "P3. a parked mission's state.json PARSES" "json_ok '$(state_of "$repoPK" "$MID")'"
check "P3. prdPending is a real JSON boolean, not the string \"true\"" \
  "[ \"\$(json_type '$(state_of "$repoPK" "$MID")' prdPending)\" = 'bool' ]"

# --- P4: attachments>0 is WARNED about (no issue-asset upload API) ---------
IFS="$TAB" read -r repoAT originAT <<<"$(new_repo)"
FIXAT="$(new_fixture "$TMPROOT/fixAT")"
mk_body "$FIXAT/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 3)"
printf 'Add dark mode\n' >"$FIXAT/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXAT/issue-42.labels"
( cd "$repoAT" && GH_FIX="$FIXAT" GH_ASSIGN_STATE="$TMPROOT/assignAT.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 )
check "P4. attachments on the original mission are WARNED about, not faked" \
  "grep -qi 'attachment' '$repoAT/out.txt'"

# --- P5: a verify adopt with NO resolvable PR is honest about the ambiguity -
IFS="$TAB" read -r repoNP originNP <<<"$(new_repo)"
FIXNP="$(new_fixture "$TMPROOT/fixNP")"
mk_body "$FIXNP/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXNP/issue-42.title"
printf 'lcars:mission\nlcars:verify\n' >"$FIXNP/issue-42.labels"
rcNP=0
( cd "$repoNP" && GH_FIX="$FIXNP" GH_ASSIGN_STATE="$TMPROOT/assignNP.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcNP=$?
check "P5. a verify mission with no resolvable PR still adopts" "[ '$rcNP' -eq 0 ]"
check "P5. it says NO PR was resolved rather than inventing one" \
  "grep -qi 'no open pr\\|could not resolve' '$repoNP/out.txt'"
check "P5. no prUrl is written" "! grep -q 'prUrl' '$(state_of "$repoNP" "$MID")'"
check "P5. and the PR-less verify state still PARSES" \
  "json_ok '$(state_of "$repoNP" "$MID")'"

# --- P6: adopt outside a git repo dies plainly ----------------------------
NOGIT="$(mktemp -d "$TMPROOT/nogit.XXXX")"
rcNG=0
( cd "$NOGIT" && GH_FIX="$FIX" LCARS_GH_USER=capt LCARS_GH_BIN="$GH" \
    bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcNG=$?
check "P6. adopt outside a git repo refuses with a plain line" \
  "[ '$rcNG' -ne 0 ] && grep -qi 'git repo' '$NOGIT/out.txt'"

# --- P7: no issue number at all -------------------------------------------
rcNI=0
( cd "$repoA" && LCARS_GH_BIN="$GH" bash "$SCRIPT" >out2.txt 2>&1 ) || rcNI=$?
check "P7. adopt with no issue number refuses" \
  "[ '$rcNI' -ne 0 ] && grep -qi 'issue' '$repoA/out2.txt'"

# ==========================================================================
echo
echo "S196 A1/A2 — identity is the ISSUE NUMBER, and a branch is never re-used"
# ==========================================================================
#
# MEASURED IN S191'S LIVE CAPSTONE (2026-09-09). Mission ids are
# `lcars-YYYYMMDD-NNN` sequenced PER CLONE, so two laptops filing on the same day
# mint the IDENTICAL id. Adopt keyed its "is this mission already here?" question
# on that id, so adopting a SECOND issue matched the FIRST local mission, printed
# "(refreshed an existing local mission — local artifacts kept)" and OVERWROTE it
# in place: title, `githubIssue` 34→35, stage done→align, and the ENTIRE merge
# record (`review`, `prNumber`, `prUrl`) gone. Silent data loss, on a mission the
# captain had already SHIPPED.
#
# `web/lcars_serve/remote.py` has always deduped on the ISSUE NUMBER and says so
# in its own rule 1 ("the dedupe key is the ISSUE NUMBER and nothing else").
# adopt now uses the same key: a different issue carrying a colliding mission id
# is a DIFFERENT mission and can never be a refresh.
#
# AND THE ID NAMES THE BRANCH (`lcars/<id>`), so the collision is not merely
# local: #35's adopt reported "local branch already here" and attached itself to
# #34's MERGED branch. The id FORMAT is frozen for this round, so adopt cannot
# re-mint its way out. What it can do — and now does — is REFUSE, loudly, and
# touch nothing. Both refusals below assert the incumbent's state.json is
# BYTE-IDENTICAL afterwards, because "we did not destroy it" is the whole claim.

# --- C1: THE HEADLINE. A colliding id from a DIFFERENT issue destroys nothing.
IFS="$TAB" read -r repoC1 originC1 <<<"$(new_repo)"
CID="lcars-20260909-001"
mkdir -p "$repoC1/.git/lcars/missions/$CID"
# Laptop A's mission, exactly as it stood after `lcars approve` shipped it: the
# merge record present, `base` LAST (file.sh's write_state shape).
cat >"$repoC1/.git/lcars/missions/$CID/state.json" <<'SHIPPED'
{
  "id": "lcars-20260909-001",
  "type": "feature",
  "title": "Laptop A's shipped mission",
  "stage": "done",
  "created": "2026-09-09T09:00:00Z",
  "model": "claude-sonnet",
  "review": "merged",
  "prNumber": "77",
  "prUrl": "https://github.com/acme/repo/pull/77",
  "githubIssue": 34,
  "branch": "lcars/lcars-20260909-001",
  "base": "main"
}
SHIPPED
sC1="$(state_of "$repoC1" "$CID")"
check "C1. the shipped incumbent is valid JSON to begin with (the test's premise)" \
  "json_ok '$sC1'"
beforeC1="$(cat "$sC1")"
cksumC1="$(cksum <"$sC1")"

# Laptop B filed on the SAME DAY, so its independently-sequenced id is the same
# string — and its branch is therefore the same branch.
FIXC1="$(new_fixture "$TMPROOT/fixC1")"
mk_body "$FIXC1/issue-35.body" "$PRD_TEXT" "$(envelope "$CID" "lcars/$CID" main feature claude null 0)"
printf "Laptop B's brand new mission\n" >"$FIXC1/issue-35.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXC1/issue-35.labels"
rcC1=0
( cd "$repoC1" && GH_FIX="$FIXC1" GH_ASSIGN_STATE="$TMPROOT/assignC1.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 35 >out.txt 2>&1 ) || rcC1=$?

check "C1. adopting a DIFFERENT issue with a colliding mission id REFUSES" \
  "[ '$rcC1' -ne 0 ]"
check "C1. it never claims to have 'refreshed an existing local mission'" \
  "! grep -qi 'refreshed an existing' '$repoC1/out.txt'"
check "C1. the incumbent's state.json is BYTE-IDENTICAL after the refusal" \
  "[ \"\$beforeC1\" = \"\$(cat '$sC1')\" ]"
check "C1. …and its checksum agrees (belt and braces)" \
  "[ \"\$cksumC1\" = \"\$(cksum <'$sC1')\" ]"
check "C1. the incumbent still PARSES (S189's lesson: every mutating path parses)" \
  "json_ok '$sC1'"
check "C1. the MERGE RECORD survives verbatim — review" \
  "[ \"\$(json_get '$sC1' review)\" = 'merged' ]"
check "C1. the MERGE RECORD survives verbatim — prNumber" \
  "[ \"\$(json_get '$sC1' prNumber)\" = '77' ]"
check "C1. the MERGE RECORD survives verbatim — prUrl" \
  "[ \"\$(json_get '$sC1' prUrl)\" = 'https://github.com/acme/repo/pull/77' ]"
check "C1. githubIssue is STILL 34 (it was rewritten to 35 in the capstone)" \
  "[ \"\$(json_get '$sC1' githubIssue)\" = '34' ]"
check "C1. the stage is STILL done (it was rewritten to align in the capstone)" \
  "[ \"\$(json_get '$sC1' stage)\" = 'done' ]"
check "C1. the title is STILL laptop A's (it was rewritten in the capstone)" \
  "[ \"\$(json_get '$sC1' title)\" = \"Laptop A's shipped mission\" ]"
check "C1. no second mission dir is half-built (still exactly one)" \
  "[ \"\$(ls -1 '$repoC1/.git/lcars/missions' | wc -l | tr -d ' ')\" = '1' ]"
check "C1. no prd.md from issue #35 is written over laptop A's mission" \
  "! grep -qs 'dark mode' '$repoC1/.git/lcars/missions/$CID/prd.md'"
check "C1. the refusal names BOTH issues, so the captain can see the collision" \
  "grep -q '35' '$repoC1/out.txt' && grep -q '34' '$repoC1/out.txt'"
check "C1. the refusal names the colliding mission id" \
  "grep -q '$CID' '$repoC1/out.txt'"
check "C1. the refusal says nothing was created / nothing touched" \
  "grep -qi 'nothing was created\\|not touched' '$repoC1/out.txt'"
check "C1. the refusal is a plain sentence, not a bash error" \
  "! grep -qi 'unbound variable\\|no such file or directory\\|syntax error' '$repoC1/out.txt'"
check "C1. a refused adopt never claims the issue on GitHub" \
  "[ ! -s '$TMPROOT/assignC1.txt' ]"
check "C1. and it cuts no local branch" \
  "[ -z \"\$(cd '$repoC1' && git branch --list 'lcars/*')\" ]"

# --- C2: the LEGITIMATE refresh path is not regressed ----------------------
# And it proves the KEY is the issue number rather than the directory name: the
# local mission for issue 42 is deliberately NOT in a directory named after its
# id, so only an issue-number lookup can find it. A dir-name lookup would create
# a SECOND mission beside it.
IFS="$TAB" read -r repoC2 originC2 <<<"$(new_repo)"
mkdir -p "$repoC2/.git/lcars/missions/legacy-dir"
cat >"$repoC2/.git/lcars/missions/legacy-dir/state.json" <<'LEGACY'
{
  "id": "lcars-20260908-042",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "align",
  "created": "2026-09-01T00:00:00Z",
  "model": "claude-sonnet",
  "baseSha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  "githubIssue": 42,
  "branch": "lcars/lcars-20260908-042",
  "base": "main"
}
LEGACY
printf 'the captain said: make it teal\n' >"$repoC2/.git/lcars/missions/legacy-dir/feedback.md"
FIXC2="$(new_fixture "$TMPROOT/fixC2")"
mk_body "$FIXC2/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode (renamed on GitHub)\n' >"$FIXC2/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXC2/issue-42.labels"
rcC2=0
( cd "$repoC2" && GH_FIX="$FIXC2" GH_ASSIGN_STATE="$TMPROOT/assignC2.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out.txt 2>&1 ) || rcC2=$?
sC2="$repoC2/.git/lcars/missions/legacy-dir/state.json"
check "C2. re-adopting the SAME issue number still exits 0 (a refresh, as before)" \
  "[ '$rcC2' -eq 0 ]"
check "C2. it refreshed the mission that CARRIES issue 42, wherever it lives" \
  "[ \"\$(json_get '$sC2' title)\" = 'Add dark mode (renamed on GitHub)' ]"
check "C2. it did NOT create a second mission keyed on the id" \
  "[ ! -d '$repoC2/.git/lcars/missions/$MID' ]"
check "C2. still exactly one mission dir" \
  "[ \"\$(ls -1 '$repoC2/.git/lcars/missions' | wc -l | tr -d ' ')\" = '1' ]"
check "C2. state.json PARSES after the refresh" "json_ok '$sC2'"
check "C2. the LOCAL-ONLY baseSha survived" \
  "[ \"\$(json_get '$sC2' baseSha)\" = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' ]"
check "C2. local-only artifacts survived" \
  "grep -q teal '$repoC2/.git/lcars/missions/legacy-dir/feedback.md'"
check "C2. the spec was rebuilt into THAT dir, not a new one" \
  "[ -f '$repoC2/.git/lcars/missions/legacy-dir/prd.md' ]"
check "C2. the readout's Next: line names the address \`lcars run\` will resolve" \
  "grep -q 'lcars run legacy-dir' '$repoC2/out.txt'"

# --- C3: two missions that do NOT collide still coexist, untouched ---------
# The positive control for C1: matching on the issue number must not have turned
# every second adopt into a refusal.
IFS="$TAB" read -r repoC3 originC3 <<<"$(new_repo)"
FIXC3="$(new_fixture "$TMPROOT/fixC3")"
AID="lcars-20260909-011"; BID="lcars-20260909-012"
mk_body "$FIXC3/issue-34.body" "$PRD_TEXT" "$(envelope "$AID" "lcars/$AID" main feature claude null 0)"
printf 'Mission A\n' >"$FIXC3/issue-34.title"
printf 'lcars:mission\nlcars:verify\n' >"$FIXC3/issue-34.labels"
printf '77%shttps://github.com/acme/repo/pull/77\n' "$TAB" >"$FIXC3/closes-34"
mk_body "$FIXC3/issue-35.body" "$PRD_TEXT" "$(envelope "$BID" "lcars/$BID" main feature claude null 0)"
printf 'Mission B\n' >"$FIXC3/issue-35.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXC3/issue-35.labels"
( cd "$repoC3" && GH_FIX="$FIXC3" GH_ASSIGN_STATE="$TMPROOT/assignC3.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 34 >out1.txt 2>&1 )
sC3a="$(state_of "$repoC3" "$AID")"
beforeC3a="$(cat "$sC3a" 2>/dev/null)"
rcC3=0
( cd "$repoC3" && GH_FIX="$FIXC3" GH_ASSIGN_STATE="$TMPROOT/assignC3.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 35 >out2.txt 2>&1 ) || rcC3=$?
sC3b="$(state_of "$repoC3" "$BID")"
check "C3. adopting a SECOND, non-colliding mission exits 0" "[ '$rcC3' -eq 0 ]"
check "C3. two SEPARATE local missions exist afterwards" \
  "[ -f '$sC3a' ] && [ -f '$sC3b' ]"
check "C3. both PARSE" "json_ok '$sC3a' && json_ok '$sC3b'"
check "C3. the first mission's state is BYTE-IDENTICAL after the second adopt" \
  "[ \"\$beforeC3a\" = \"\$(cat '$sC3a')\" ]"
check "C3. the first mission keeps its own issue number" \
  "[ \"\$(json_get '$sC3a' githubIssue)\" = '34' ]"
check "C3. the first mission keeps its PR record" \
  "[ \"\$(json_get '$sC3a' review)\" = 'open' ] && [ \"\$(json_get '$sC3a' prNumber)\" = '77' ]"
check "C3. the second mission carries ITS issue number" \
  "[ \"\$(json_get '$sC3b' githubIssue)\" = '35' ]"

# --- D1: A2 — an adopt that would RE-USE another issue's branch refuses -----
# Ids that differ but a branch that does not: the id guard cannot see this, and
# it is the half of the collision that lives on the SHARED remote. Adopting here
# would point two missions at one ref and hand the newcomer #34's history — which
# is exactly what the capstone's "local branch already here" line did.
IFS="$TAB" read -r repoD1 originD1 <<<"$(new_repo)"
mkdir -p "$repoD1/.git/lcars/missions/lcars-20260909-007"
cat >"$repoD1/.git/lcars/missions/lcars-20260909-007/state.json" <<'HELD'
{
  "id": "lcars-20260909-007",
  "type": "feature",
  "title": "The mission that owns the branch",
  "stage": "done",
  "created": "2026-09-09T09:00:00Z",
  "model": "claude-sonnet",
  "review": "merged",
  "prNumber": "77",
  "prUrl": "https://github.com/acme/repo/pull/77",
  "githubIssue": 34,
  "branch": "lcars/shared-branch",
  "base": "main"
}
HELD
sD1="$(state_of "$repoD1" "lcars-20260909-007")"
check "D1. the branch-holding incumbent is valid JSON to begin with" "json_ok '$sD1'"
beforeD1="$(cat "$sD1")"
FIXD1="$(new_fixture "$TMPROOT/fixD1")"
mk_body "$FIXD1/issue-35.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260910-008" "lcars/shared-branch" main feature claude null 0)"
printf 'A different mission, the same branch\n' >"$FIXD1/issue-35.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXD1/issue-35.labels"
rcD1=0
( cd "$repoD1" && GH_FIX="$FIXD1" GH_ASSIGN_STATE="$TMPROOT/assignD1.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 35 >out.txt 2>&1 ) || rcD1=$?
check "D1. an adopt that would re-use another issue's branch REFUSES" \
  "[ '$rcD1' -ne 0 ]"
check "D1. the refusal names the branch" "grep -q 'lcars/shared-branch' '$repoD1/out.txt'"
check "D1. the refusal names the issue that already owns it" \
  "grep -q '34' '$repoD1/out.txt'"
check "D1. the refusal is a legible sentence, not a bash error" \
  "! grep -qi 'unbound variable\\|no such file or directory\\|syntax error' '$repoD1/out.txt'"
check "D1. the incumbent's state.json is BYTE-IDENTICAL after the refusal" \
  "[ \"\$beforeD1\" = \"\$(cat '$sD1')\" ]"
check "D1. the incumbent still PARSES" "json_ok '$sD1'"
check "D1. its merge record is untouched" \
  "[ \"\$(json_get '$sD1' review)\" = 'merged' ] && [ \"\$(json_get '$sD1' prUrl)\" = 'https://github.com/acme/repo/pull/77' ]"
check "D1. NOTHING new is on disk (still exactly one mission dir)" \
  "[ \"\$(ls -1 '$repoD1/.git/lcars/missions' | wc -l | tr -d ' ')\" = '1' ]"
check "D1. no mission dir was created for the newcomer's id" \
  "[ ! -d '$repoD1/.git/lcars/missions/lcars-20260910-008' ]"
check "D1. a refused adopt never claims the issue on GitHub" \
  "[ ! -s '$TMPROOT/assignD1.txt' ]"
check "D1. and it cuts no local branch" \
  "[ -z \"\$(cd '$repoD1' && git branch --list 'lcars/*')\" ]"

# --- D2: the branch guard does not fire on the mission's OWN branch --------
# A refresh re-reads the same envelope, so the recorded branch is by definition
# the one this mission already holds. If the guard keyed on the branch alone it
# would make every second adopt impossible.
IFS="$TAB" read -r repoD2 originD2 <<<"$(new_repo)"
FIXD2="$(new_fixture "$TMPROOT/fixD2")"
mk_body "$FIXD2/issue-42.body" "$PRD_TEXT" "$(envelope "$MID" "lcars/$MID" main feature claude null 0)"
printf 'Add dark mode\n' >"$FIXD2/issue-42.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXD2/issue-42.labels"
( cd "$repoD2" && GH_FIX="$FIXD2" GH_ASSIGN_STATE="$TMPROOT/assignD2.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out1.txt 2>&1 )
rcD2=0
( cd "$repoD2" && GH_FIX="$FIXD2" GH_ASSIGN_STATE="$TMPROOT/assignD2.txt" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >out2.txt 2>&1 ) || rcD2=$?
check "D2. re-adopting the same issue is NOT read as re-using its own branch" \
  "[ '$rcD2' -eq 0 ]"
check "D2. state.json PARSES after that refresh" "json_ok '$(state_of "$repoD2" "$MID")'"


# ==========================================================================
echo
echo "S196 A3 — THE ENGINE IS AN EXPLICIT CHOICE AT THE HANDOFF"
# ==========================================================================
# THE DEFECT, measured in S191's capstone with shims faking both CLIs. A mission
# was filed `--engine copilot`; the envelope carried copilot; adopt correctly
# wrote `workerBin: copilot`; the adopting clone's config.json said claude. The
# run made 3 invocations of the BILLED shim and 0 of the free one — because
# run.sh's precedence put `config.json workerBin` ABOVE the mission's own record.
# The captain is billed and nothing anywhere says why. Meanwhile approve.sh:567
# does the OPPOSITE (it exports LCARS_WORKER_BIN from the mission's engine): two
# paths, two answers.
#
# THE CAPTAIN'S RULING (2026-09-09) is NOT "the mission always wins" — a laptop
# may only have ONE CLI installed. It is ASK AND CONVERT: adopt probes what this
# machine actually has, uses the mission's engine when it is here (and SAYS so),
# ASKS and converts when it is not, asks when both exist and the local config
# disagrees (defaulting to the mission's), RECORDS the answer, and from then on
# that record outranks config.json. Non-interactive: use the mission's engine if
# available, otherwise FAIL LOUDLY. A silent switch is the defect.
#
# EVERY CLAIM ABOUT WHICH ENGINE RAN IS PROVED BY SHIM INVOCATION COUNT. A claim
# without a count is worthless — that is the whole lesson of the capstone, where
# the log said one thing and the billing said another.

# --- the two shims --------------------------------------------------------
# Real executables named `claude` and `copilot`, recording their argv. Both the
# DETECTION half (`command -v`, the ONE shared detector in lcars-common.sh) and
# the SPAWN half (run.sh's worker_spawn) see exactly these.
SHIMBIN="$TMPROOT/shimbin"; mkdir -p "$SHIMBIN"
SHIMLOG="$TMPROOT/shimlog"; mkdir -p "$SHIMLOG"
mk_shim() { # <name>
  cat >"$SHIMBIN/$1" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SHIMLOG/$1.log"
exit 0
SH
  chmod +x "$SHIMBIN/$1"
}
mk_shim claude
mk_shim copilot
mk_shim claude-cfg          # a THIRD, distinct bin so "config won" is countable
shim_count() { # <name> → invocations
  if [ -f "$SHIMLOG/$1.log" ]; then grep -c . "$SHIMLOG/$1.log" | tr -d ' '; else echo 0; fi
}
shim_model_count() { # <name> → invocations that carried --model (would have billed a tier)
  if [ -f "$SHIMLOG/$1.log" ]; then grep -c -- '--model' "$SHIMLOG/$1.log" | tr -d ' '; else echo 0; fi
}
shim_reset() { rm -f "$SHIMLOG"/*.log; }

# THE ABSENCE PATH must be real absence, not a mocked answer: a $PATH that
# genuinely does not resolve either CLI. /usr/bin:/bin carries git, awk, sed and
# mktemp and (on this project's machines) neither engine — asserted, not assumed,
# so this suite cannot pass for the wrong reason on someone else's laptop.
BARE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
check "E0. the bare PATH really resolves NEITHER engine (the absence is real)" \
  "! PATH='$BARE_PATH' command -v claude >/dev/null 2>&1 && ! PATH='$BARE_PATH' command -v copilot >/dev/null 2>&1"
BOTH_PATH="$SHIMBIN:$BARE_PATH"
GIT_ABS="$(command -v git)"
PY_DIR="$(dirname "$(command -v python3)")"

RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"

# adopt_engine <repo> <fixture> <issue> <PATH> [env=val…]  → runs adopt
adopt_engine() { # repo fixture issue path [extra env / stdin via ADOPT_STDIN]
  local repo="$1" fix="$2" issue="$3" pth="$4"; shift 4
  ( cd "$repo" && env PATH="$pth" GH_FIX="$fix" LCARS_GH_BIN="$GH" \
      LCARS_GIT_BIN="$GIT_ABS" LCARS_GH_USER=capt \
      GH_ASSIGN_STATE="$TMPROOT/assign-eng.txt" \
      "$@" bash "$SCRIPT" --issue "$issue" )
}

# spawn_with <repo> <mission> <PATH> → drive run.sh's REAL spawn chokepoint once
# through whatever bin the resolver picks, so the argv is recorded by a shim.
spawn_with() { # repo mission path
  # `env` wants its -u options BEFORE any NAME=VALUE assignment. The host markers
  # are scrubbed so this session's own CLAUDECODE=1 can never decide the answer.
  ( cd "$1" && env -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL \
      -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      PATH="$3:$PY_DIR" \
      bash "$RUN_SH" spawn-stage plan --mission "$2" >/dev/null 2>&1 )
}

# --- E1: the mission's engine is here, the clone's config disagrees --------
# The capstone's exact shape. NON-INTERACTIVE (no tty): the ruling says use the
# mission's engine when it is available, without asking, and say so.
IFS="$TAB" read -r repoE1 originE1 <<<"$(new_repo)"
cat >"$repoE1/.git/lcars/config.json" <<'CFG'
{
  "model": "claude-sonnet",
  "workerBin": "claude",
  "testCommand": "true"
}
CFG
FIXE1="$(new_fixture "$TMPROOT/fixE1")"
mk_body "$FIXE1/issue-50.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-050" "lcars/lcars-20260909-050" main feature copilot null 0)"
printf 'A copilot mission\n' >"$FIXE1/issue-50.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXE1/issue-50.labels"
outE1="$(adopt_engine "$repoE1" "$FIXE1" 50 "$BOTH_PATH" </dev/null 2>&1)"
sE1="$(state_of "$repoE1" "lcars-20260909-050")"
check "E1. adopt succeeds when the mission's engine is installed here" "[ -f '$sE1' ]"
check "E1. state.json PARSES" "json_ok '$sE1'"
check "E1. the MISSION's engine is recorded, not the clone's config" \
  "[ \"\$(json_get '$sE1' workerBin)\" = 'copilot' ]"
check "E1. the provenance is RECORDED at the moment of choice" \
  "[ \"\$(json_get '$sE1' engineSource)\" = 'adopt-kept' ]"
check "E1. and so is the engine it resolved to" \
  "[ \"\$(json_get '$sE1' engineResolved)\" = 'copilot' ]"
check "E1. the readout TELLS the captain which engine takes over" \
  "printf '%s' \"\$outE1\" | grep -qi 'engine' && printf '%s' \"\$outE1\" | grep -q 'copilot'"
check "E1. and names the config it is overruling, rather than doing it silently" \
  "printf '%s' \"\$outE1\" | grep -q 'claude'"
# THE COUNT. Nothing else settles this.
shim_reset
spawn_with "$repoE1" "lcars-20260909-050" "$BOTH_PATH"
check "E1. THE COUNT: the free engine ran" "[ \"\$(shim_count copilot)\" -ge 1 ]"
check "E1. THE COUNT: the BILLED engine ran ZERO times" "[ \"\$(shim_count claude)\" -eq 0 ]"
# THE TWO PRODUCERS MUST NOT FIGHT. run.sh's resolver records the same pair on
# every resolution; when the MISSION's pin is what wins, adopt's record is that
# same fact with more provenance ("kept at the handoff"), so the resolver leaves
# it alone. Without this the captain's answer at the handoff would be erased by
# the first run — provenance that does not survive is not provenance.
( cd "$repoE1" && env -u LCARS_WORKER_BIN -u CLAUDECODE PATH="$BOTH_PATH:$PY_DIR" \
    bash "$RUN_SH" resolve-worker --mission lcars-20260909-050 >/dev/null 2>&1 )
check "E1. a real resolution does NOT erase adopt's richer provenance" \
  "[ \"\$(json_get '$sE1' engineSource)\" = 'adopt-kept' ]"
check "E1. state.json still PARSES after the resolver touched it" "json_ok '$sE1'"
# The BILLED engine is the one that must show nothing at all — including no
# `--model`, the flag that selects a paid tier. (The free engine's Plan spawn
# DOES carry `--model claude-opus-4.8`: that is run.sh's per-stage tier alias
# for copilot, a copilot premium request rather than an Anthropic bill, and it
# is the correct existing behaviour. Counted and reported, not asserted away.)
check "E1. THE COUNT: the billed engine carried --model ZERO times" \
  "[ \"\$(shim_model_count claude)\" -eq 0 ]"

# --- E2: the mission's engine is NOT on this machine → ASK and CONVERT -----
# The reason the ruling is "ask", not "the mission always wins": this laptop has
# only claude. Refusing forever would strand the mission; switching silently is
# the defect. So adopt asks, and RECORDS the answer.
IFS="$TAB" read -r repoE2 originE2 <<<"$(new_repo)"
cat >"$repoE2/.git/lcars/config.json" <<'CFG'
{
  "model": "claude-sonnet",
  "workerBin": "claude-cfg",
  "testCommand": "true"
}
CFG
CLAUDE_ONLY="$SHIMBIN/claude-only"
mkdir -p "$CLAUDE_ONLY"
ln -sf "$SHIMBIN/claude" "$CLAUDE_ONLY/claude"
ln -sf "$SHIMBIN/claude-cfg" "$CLAUDE_ONLY/claude-cfg"
ONLY_CLAUDE_PATH="$CLAUDE_ONLY:$BARE_PATH"
check "E2. the one-CLI PATH really has claude and really has NO copilot" \
  "PATH='$ONLY_CLAUDE_PATH' command -v claude >/dev/null 2>&1 && ! PATH='$ONLY_CLAUDE_PATH' command -v copilot >/dev/null 2>&1"
FIXE2="$(new_fixture "$TMPROOT/fixE2")"
mk_body "$FIXE2/issue-51.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-051" "lcars/lcars-20260909-051" main feature copilot null 0)"
printf 'A copilot mission on a claude-only laptop\n' >"$FIXE2/issue-51.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXE2/issue-51.labels"
outE2="$(printf 'claude\n' | adopt_engine "$repoE2" "$FIXE2" 51 "$ONLY_CLAUDE_PATH" LCARS_ASSUME_TTY=1 2>&1)"
sE2="$(state_of "$repoE2" "lcars-20260909-051")"
check "E2. adopt ASKED rather than deciding for the captain" \
  "printf '%s' \"\$outE2\" | grep -qi 'not installed\\|is not on this machine\\|which engine'"
check "E2. the mission was adopted after the answer" "[ -f '$sE2' ]"
check "E2. state.json PARSES" "json_ok '$sE2'"
check "E2. the CONVERTED engine is recorded on the mission" \
  "[ \"\$(json_get '$sE2' workerBin)\" = 'claude' ]"
check "E2. and it is recorded AS a conversion, not as the mission's own pin" \
  "[ \"\$(json_get '$sE2' engineSource)\" = 'adopt-converted' ]"
shim_reset
spawn_with "$repoE2" "lcars-20260909-051" "$ONLY_CLAUDE_PATH"
check "E2. THE COUNT: the CONVERTED engine ran" "[ \"\$(shim_count claude)\" -ge 1 ]"
check "E2. THE COUNT: config.json's engine ran ZERO times — the record outranks it" \
  "[ \"\$(shim_count claude-cfg)\" -eq 0 ]"
check "E2. THE COUNT: the engine config wanted carried --model ZERO times" \
  "[ \"\$(shim_model_count claude-cfg)\" -eq 0 ]"

# --- E3: NON-INTERACTIVE + the mission's engine unavailable → FAIL LOUDLY --
# Never switch silently. A loud failure is the cure; a quiet conversion is the
# defect wearing the cure's clothes.
IFS="$TAB" read -r repoE3 originE3 <<<"$(new_repo)"
FIXE3="$(new_fixture "$TMPROOT/fixE3")"
mk_body "$FIXE3/issue-52.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-052" "lcars/lcars-20260909-052" main feature copilot null 0)"
printf 'Unrunnable here\n' >"$FIXE3/issue-52.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXE3/issue-52.labels"
rcE3=0
outE3="$(adopt_engine "$repoE3" "$FIXE3" 52 "$ONLY_CLAUDE_PATH" \
           GH_ASSIGN_STATE="$TMPROOT/assignE3.txt" </dev/null 2>&1)" || rcE3=$?
check "E3. a non-interactive adopt with no usable engine REFUSES" "[ '$rcE3' -ne 0 ]"
check "E3. it names the engine the mission needs" "printf '%s' \"\$outE3\" | grep -q 'copilot'"
check "E3. it names what this machine HAS instead" "printf '%s' \"\$outE3\" | grep -q 'claude'"
check "E3. it says how to convert on purpose" "printf '%s' \"\$outE3\" | grep -q -- '--engine'"
check "E3. it is a legible sentence, not a bash error" \
  "! printf '%s' \"\$outE3\" | grep -qi 'unbound variable\\|syntax error'"
check "E3. IT SWITCHED NOTHING: no mission dir exists" \
  "[ ! -d '$repoE3/.git/lcars/missions/lcars-20260909-052' ]"
check "E3. IT RECORDED NOTHING: the missions dir is still empty" \
  "[ -z \"\$(ls -A '$repoE3/.git/lcars/missions' 2>/dev/null)\" ]"
check "E3. and it did not claim the issue on GitHub" "[ ! -s '$TMPROOT/assignE3.txt' ]"

# --- E3b: --engine converts non-interactively, ON PURPOSE ------------------
# Driven directly rather than through adopt_engine, which appends `--issue` last.
rcE3c=0
outE3c="$( cd "$repoE3" && env PATH="$ONLY_CLAUDE_PATH" GH_FIX="$FIXE3" \
    LCARS_GH_BIN="$GH" LCARS_GIT_BIN="$GIT_ABS" LCARS_GH_USER=capt \
    GH_ASSIGN_STATE="$TMPROOT/assignE3.txt" \
    bash "$SCRIPT" --issue 52 --engine claude </dev/null 2>&1 )" || rcE3c=$?
sE3="$(state_of "$repoE3" "lcars-20260909-052")"
check "E3b. \`--engine\` converts without a tty (a deliberate operator act)" "[ '$rcE3c' -eq 0 ]"
check "E3b. state.json PARSES" "json_ok '$sE3'"
check "E3b. the converted engine is recorded" \
  "[ \"\$(json_get '$sE3' workerBin)\" = 'claude' ]"
check "E3b. recorded as a conversion" \
  "[ \"\$(json_get '$sE3' engineSource)\" = 'adopt-converted' ]"

# --- E4: BOTH engines here and the local config disagrees → ASK, default to
#         the mission's. An empty answer takes the default. ----------------
IFS="$TAB" read -r repoE4 originE4 <<<"$(new_repo)"
cat >"$repoE4/.git/lcars/config.json" <<'CFG'
{
  "model": "claude-sonnet",
  "workerBin": "claude",
  "testCommand": "true"
}
CFG
FIXE4="$(new_fixture "$TMPROOT/fixE4")"
mk_body "$FIXE4/issue-53.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-053" "lcars/lcars-20260909-053" main feature copilot null 0)"
printf 'Both installed, config disagrees\n' >"$FIXE4/issue-53.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXE4/issue-53.labels"
outE4="$(printf '\n' | adopt_engine "$repoE4" "$FIXE4" 53 "$BOTH_PATH" LCARS_ASSUME_TTY=1 2>&1)"
sE4="$(state_of "$repoE4" "lcars-20260909-053")"
check "E4. adopt ASKS when both exist and the config disagrees" \
  "printf '%s' \"\$outE4\" | grep -qi 'which engine\\|\\[copilot\\]'"
check "E4. state.json PARSES" "json_ok '$sE4'"
check "E4. the DEFAULT is the mission's engine" \
  "[ \"\$(json_get '$sE4' workerBin)\" = 'copilot' ]"
check "E4. and the answer is recorded as the captain's choice" \
  "[ \"\$(json_get '$sE4' engineSource)\" = 'adopt-chosen' ]"
shim_reset
spawn_with "$repoE4" "lcars-20260909-053" "$BOTH_PATH"
check "E4. THE COUNT: the chosen engine ran" "[ \"\$(shim_count copilot)\" -ge 1 ]"
check "E4. THE COUNT: the config engine ran ZERO times" "[ \"\$(shim_count claude)\" -eq 0 ]"

# --- E4b: the captain overrules the mission at the prompt ------------------
IFS="$TAB" read -r repoE4b originE4b <<<"$(new_repo)"
cat >"$repoE4b/.git/lcars/config.json" <<'CFG'
{ "model": "claude-sonnet", "workerBin": "claude", "testCommand": "true" }
CFG
outE4b="$(printf 'claude\n' | adopt_engine "$repoE4b" "$FIXE4" 53 "$BOTH_PATH" LCARS_ASSUME_TTY=1 2>&1)"
sE4b="$(state_of "$repoE4b" "lcars-20260909-053")"
check "E4b. an explicit answer at the prompt WINS over the default" \
  "[ \"\$(json_get '$sE4b' workerBin)\" = 'claude' ]"
check "E4b. state.json PARSES" "json_ok '$sE4b'"
shim_reset
spawn_with "$repoE4b" "lcars-20260909-053" "$BOTH_PATH"
check "E4b. THE COUNT: the captain's pick ran" "[ \"\$(shim_count claude)\" -ge 1 ]"
check "E4b. THE COUNT: the mission's original engine ran ZERO times" \
  "[ \"\$(shim_count copilot)\" -eq 0 ]"

# --- E5: no config workerBin at all → no question is asked -----------------
# Asking when nothing disagrees would be noise. The mission's engine is here and
# nothing contradicts it: use it, say so, move on.
IFS="$TAB" read -r repoE5 originE5 <<<"$(new_repo)"
outE5="$(printf 'claude\n' | adopt_engine "$repoE5" "$FIXE4" 53 "$BOTH_PATH" LCARS_ASSUME_TTY=1 2>&1)"
sE5="$(state_of "$repoE5" "lcars-20260909-053")"
check "E5. no prompt when nothing disagrees" \
  "! printf '%s' \"\$outE5\" | grep -qi 'which engine'"
check "E5. the mission's engine is kept" "[ \"\$(json_get '$sE5' workerBin)\" = 'copilot' ]"
check "E5. recorded as kept" "[ \"\$(json_get '$sE5' engineSource)\" = 'adopt-kept' ]"
check "E5. state.json PARSES" "json_ok '$sE5'"

# --- E6: an envelope with NO engine records nothing and asks nothing -------
# `engine: null` means host-detection is legitimately in charge (S188). Adopt
# must not invent a pin the filing laptop deliberately did not make.
IFS="$TAB" read -r repoE6 originE6 <<<"$(new_repo)"
FIXE6="$(new_fixture "$TMPROOT/fixE6")"
mk_body "$FIXE6/issue-54.body" "$PRD_TEXT" \
  "$(printf '<!-- lcars:handoff v1 {"id":"lcars-20260909-054","branch":"lcars/lcars-20260909-054","base":"main","type":"feature","engine":null,"parentIssue":null,"attachments":0} -->')"
printf 'No engine recorded\n' >"$FIXE6/issue-54.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXE6/issue-54.labels"
rcE6=0
outE6="$(adopt_engine "$repoE6" "$FIXE6" 54 "$BOTH_PATH" </dev/null 2>&1)" || rcE6=$?
sE6="$(state_of "$repoE6" "lcars-20260909-054")"
check "E6. an engine-less envelope adopts cleanly" "[ '$rcE6' -eq 0 ]"
check "E6. state.json PARSES" "json_ok '$sE6'"
check "E6. no workerBin is invented" "! json_has '$sE6' workerBin"
check "E6. and no engine provenance is invented either" "! json_has '$sE6' engineSource"

# --- E7: the shared library is MISSING → degraded, not refusing -----------
# adopt reaches the engine detector through lcars-common.sh. If that file is
# gone (a half-installed LCARS), the naive read is "no engine is available" —
# and a non-interactive adopt would then REFUSE a mission this machine can run
# perfectly well. A missing helper must degrade, never turn into a hard no.
IFS="$TAB" read -r repoE7 originE7 <<<"$(new_repo)"
rcE7=0
outE7="$( cd "$repoE7" && env PATH="$BOTH_PATH" GH_FIX="$FIXE4" \
    LCARS_GH_BIN="$GH" LCARS_GIT_BIN="$GIT_ABS" LCARS_GH_USER=capt \
    LCARS_COMMON_LIB=/nonexistent/lcars-common.sh \
    bash "$SCRIPT" --issue 53 </dev/null 2>&1 )" || rcE7=$?
sE7="$(state_of "$repoE7" "lcars-20260909-053")"
check "E7. a missing lcars-common.sh does NOT turn adopt into a refusal" \
  "[ '$rcE7' -eq 0 ]"
check "E7. state.json PARSES" "json_ok '$sE7'"
check "E7. the mission's engine is still recognised as installed here" \
  "[ \"\$(json_get '$sE7' workerBin)\" = 'copilot' ]"

# ==========================================================================
echo
echo "E8 — the captain's answer at the adopt prompt SURVIVES \`lcars approve\`"
# ==========================================================================
# THE WHOLE POINT OF S196, end to end, with nothing faked between the two verbs:
# a real `lcars adopt` ASKS which engine to use on this laptop, the captain
# answers, adopt RECORDS `adopt-chosen` — and then the real `lcars approve`
# merges the mission and the answer is STILL THERE.
#
# It was not. Measured three separate times in one day (S196 capstone): the card
# went from `copilot · chosen at adopt` to `copilot · $LCARS_WORKER_BIN` the
# moment approve ran. approve pins the mission's engine for its reconcile leg —
# correct, and it stays — and run.sh's recorder mistook LCARS's own re-assertion
# of the mission's engine for a fresh operator act, overwriting the more specific
# truth with `env`. The engine never moved; the reason it ran did.
#
# approve's reconcile here is the REAL run.sh, not a stub: the defect lives in
# the handshake BETWEEN the two scripts, so a stub cannot have it. It costs
# nothing — the fixture's base is never ahead of the mission branch, so the
# reconcile gate returns before a worker exists — and both engines are on $PATH
# as argv-recording shims whose counts are asserted ZERO, so a future change that
# does reach for a worker is caught as a count rather than a bill.
IFS="$TAB" read -r repoE8 originE8 <<<"$(new_repo)"
cat >"$repoE8/.git/lcars/config.json" <<'CFG'
{
  "model": "claude-sonnet",
  "workerBin": "claude",
  "testCommand": "true"
}
CFG
E8_MID="lcars-20260909-055"
FIXE8="$(new_fixture "$TMPROOT/fixE8")"
mk_body "$FIXE8/issue-55.body" "$PRD_TEXT" \
  "$(envelope "$E8_MID" "lcars/$E8_MID" main feature copilot null 0)"
printf 'A copilot mission at verify\n' >"$FIXE8/issue-55.title"
printf 'lcars:mission\nlcars:verify\n' >"$FIXE8/issue-55.labels"
printf '77%shttps://github.com/acme/repo/pull/77\n' "$TAB" >"$FIXE8/closes-55"
seed_branch "$originE8" "lcars/$E8_MID"
ASSIGN_E8="$TMPROOT/assign-e8.txt"; : >"$ASSIGN_E8"

# 1. ADOPT — both engines here, the clone's config disagrees ⇒ it ASKS. An empty
#    answer takes the default (the mission's own engine).
outE8="$(printf '\n' | ( cd "$repoE8" && env PATH="$BOTH_PATH" GH_FIX="$FIXE8" \
    LCARS_GH_BIN="$GH" LCARS_GIT_BIN="$GIT_ABS" LCARS_GH_USER=capt \
    GH_ASSIGN_STATE="$ASSIGN_E8" LCARS_ASSUME_TTY=1 \
    bash "$SCRIPT" --issue 55 2>&1 ))"
sE8="$(state_of "$repoE8" "$E8_MID")"
check "E8. adopt at verify ASKS which engine to use here" \
  "printf '%s' \"\$outE8\" | grep -qi 'which engine\\|\\[copilot\\]'"
check "E8. the captain's answer is recorded as adopt-chosen" \
  "[ \"\$(json_get '$sE8' engineSource)\" = 'adopt-chosen' ]"
check "E8. …on the engine he chose" "[ \"\$(json_get '$sE8' workerBin)\" = 'copilot' ]"
check "E8. state.json PARSES after adopt" "json_ok '$sE8'"

# 2. APPROVE — the real merge gate, with the real run.sh as its reconcile.
shim_reset
: >"$GH_LOG"
rcE8=0
( cd "$repoE8" && env -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
    -u LCARS_WORKER_BIN -u LCARS_WORKER_BIN_INTERNAL \
    PATH="$BOTH_PATH:$PY_DIR" GH_FIX="$FIXE8" GH_ASSIGN_STATE="$ASSIGN_E8" \
    LCARS_GH_USER=capt LCARS_GH_BIN="$GH" LCARS_GIT_BIN="$GIT_ABS" \
    LCARS_RUN_SCRIPT="$RUN_SH" \
    bash "$APPROVE_SCRIPT" --mission "$E8_MID" >approve.txt 2>&1 ) || rcE8=$?
check "E8. approve ships the adopted mission" \
  "[ '$rcE8' -eq 0 ] && [ \"\$(json_get '$sE8' stage)\" = 'done' ]"
check "E8. THE HEADLINE: the adopt answer SURVIVES the merge" \
  "[ \"\$(json_get '$sE8' engineSource)\" = 'adopt-chosen' ]"
check "E8. approve did NOT rewrite the provenance to \`env\`" \
  "[ \"\$(json_get '$sE8' engineSource)\" != 'env' ]"
check "E8. the engine itself is unchanged" \
  "[ \"\$(json_get '$sE8' engineResolved)\" = 'copilot' ] && [ \"\$(json_get '$sE8' workerBin)\" = 'copilot' ]"
check "E8. state.json PARSES after approve wrote to it" "json_ok '$sE8'"
check "E8. THE COUNT: approve's reconcile spawned NO worker at all" \
  "[ \"\$(shim_count copilot)\" -eq 0 ] && [ \"\$(shim_count claude)\" -eq 0 ]"

# ==========================================================================
echo
echo "S196 A4 — AN ADOPTED CLONE CAN ACTUALLY RUN THE MISSION"
# ==========================================================================
# An adopted clone had no config.json at all: no testCommand, so the Implement
# red gate has nothing to run, and no stack, so no stage knows the ecosystem.
# Adopt DID warn — and the board's ADOPT dispatch swallowed the warning, showing
# only "Adopted #34 — it is a local mission now." A warning nobody sees is not a
# warning. So adopt SEEDS a usable config, through the SAME shared detectors
# `lcars init` uses (lcars-common.sh), never a second implementation of them.
IFS="$TAB" read -r repoF1 originF1 <<<"$(new_repo)"
rm -f "$repoF1/.git/lcars/config.json"          # a genuinely cold clone
mkdir -p "$repoF1/tests"
printf '{ "name": "x", "scripts": { "test": "vitest run" }, "devDependencies": { "vitest": "^1" } }\n' \
  >"$repoF1/package.json"
printf 'test("x", () => {});\n' >"$repoF1/tests/x.test.js"
FIXF1="$(new_fixture "$TMPROOT/fixF1")"
mk_body "$FIXF1/issue-60.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-060" "lcars/lcars-20260909-060" main feature claude null 0)"
printf 'Cold clone\n' >"$FIXF1/issue-60.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXF1/issue-60.labels"
outF1="$(adopt_engine "$repoF1" "$FIXF1" 60 "$BOTH_PATH" </dev/null 2>&1)"
CFGF1="$repoF1/.git/lcars/config.json"
check "F1. adopt SEEDS a config.json on a cold clone" "[ -f '$CFGF1' ]"
check "F1. and it is valid JSON" "json_ok '$CFGF1'"
check "F1. the adopted mission HAS a testCommand" \
  "[ -n \"\$(json_get '$CFGF1' testCommand)\" ]"
check "F1. the stack was detected, not left blank" \
  "[ -n \"\$(json_get '$CFGF1' stack)\" ]"
check "F1. the seeding is REPORTED, not done behind the captain's back" \
  "printf '%s' \"\$outF1\" | grep -qi 'config.json'"
check "F1. state.json still PARSES" "json_ok '$(state_of "$repoF1" "lcars-20260909-060")'"

# A repo LCARS cannot read a test system out of must still be honest: seed what
# can be seeded, and WARN about what cannot — never manufacture a testCommand.
IFS="$TAB" read -r repoF2 originF2 <<<"$(new_repo)"
rm -f "$repoF2/.git/lcars/config.json"
FIXF2="$(new_fixture "$TMPROOT/fixF2")"
mk_body "$FIXF2/issue-61.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-061" "lcars/lcars-20260909-061" main feature claude null 0)"
printf 'Greenfield clone\n' >"$FIXF2/issue-61.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXF2/issue-61.labels"
outF2="$(adopt_engine "$repoF2" "$FIXF2" 61 "$BOTH_PATH" </dev/null 2>&1)"
CFGF2="$repoF2/.git/lcars/config.json"
check "F2. a stackless repo still gets a config.json" "[ -f '$CFGF2' ]"
check "F2. and it PARSES" "json_ok '$CFGF2'"
check "F2. no testCommand is MANUFACTURED where there is no test system" \
  "[ -z \"\$(json_get '$CFGF2' testCommand)\" ]"
check "F2. and the captain is TOLD, in adopt's own warning channel" \
  "printf '%s' \"\$outF2\" | grep -q '⚠'"

# An EXISTING config is never clobbered — a captain's customised testCommand
# survives an adopt (the merge-preserving writer, same as `lcars init`).
IFS="$TAB" read -r repoF3 originF3 <<<"$(new_repo)"
cat >"$repoF3/.git/lcars/config.json" <<'CFG'
{
  "model": "claude-sonnet",
  "testCommand": "make captains-own-suite"
}
CFG
FIXF3="$(new_fixture "$TMPROOT/fixF3")"
mk_body "$FIXF3/issue-62.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-062" "lcars/lcars-20260909-062" main feature claude null 0)"
printf 'Existing config\n' >"$FIXF3/issue-62.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXF3/issue-62.labels"
adopt_engine "$repoF3" "$FIXF3" 62 "$BOTH_PATH" </dev/null >/dev/null 2>&1
check "F3. a captain's own testCommand survives an adopt" \
  "[ \"\$(json_get '$repoF3/.git/lcars/config.json' testCommand)\" = 'make captains-own-suite' ]"
check "F3. the config still PARSES" "json_ok '$repoF3/.git/lcars/config.json'"

# ==========================================================================
echo
echo "S196 A5 — THE ESTIMATE SURVIVES THE HANDOFF"
# ==========================================================================
# A REMOTE card carries a cost pill and two difficulty pills. The instant the
# captain adopted it they vanished, because adopt rebuilt prd.md + state.json and
# not estimate.json — a visible DOWNGRADE at the exact moment he took ownership.
#
# The values come from the S188 ENVELOPE, which now carries the three pill facts
# as recorded fields. NEVER from re-scanning the captain's prose: he writes PRDs
# *about LCARS*, and behaviour P1 already hands adopt a PRD quoting a DECOY
# envelope and requires the recorded facts to win. A regex over "## Estimate"
# would be handed that document too.
est_envelope() { # id branch base type engine parent attach unit low high reason impl
  printf '<!-- lcars:handoff v1 {"id":"%s","branch":"%s","base":"%s","type":"%s","engine":"%s","parentIssue":%s,"attachments":%s,"estCostUnit":"%s","estCostLow":%s,"estCostHigh":%s,"estReasoning":"%s","estImpl":"%s"} -->' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}"
}
IFS="$TAB" read -r repoG1 originG1 <<<"$(new_repo)"
FIXG1="$(new_fixture "$TMPROOT/fixG1")"
# The PRD talks about estimates and quotes a DECOY envelope with different
# numbers — the S189 trap, re-armed for the estimate.
G1_PRD='# Mission: Add dark mode

Our board shows `**Criticality:** reasoning = LOW · implementation = LOW` and a
cost of `$99.00–$99.00` on some cards. A quoted envelope for illustration:

<!-- lcars:handoff v1 {"id":"decoy","branch":"lcars/decoy","base":"decoy","type":"bug","engine":"claude","parentIssue":null,"attachments":0,"estCostUnit":"usd","estCostLow":99,"estCostHigh":99,"estReasoning":"low","estImpl":"low"} -->

## Estimate
**Criticality:** reasoning = LOW · implementation = LOW'
mk_body "$FIXG1/issue-70.body" "$G1_PRD" \
  "$(est_envelope "lcars-20260909-070" "lcars/lcars-20260909-070" main feature copilot null 0 \
       usd 1.25 4.5 high medium)"
printf 'Estimate carries over\n' >"$FIXG1/issue-70.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXG1/issue-70.labels"
adopt_engine "$repoG1" "$FIXG1" 70 "$BOTH_PATH" </dev/null >/dev/null 2>&1
EG1="$(mdir_of "$repoG1" "lcars-20260909-070")/estimate.json"
check "G1. adopt writes an estimate.json" "[ -f '$EG1' ]"
check "G1. and it PARSES" "json_ok '$EG1'"
check "G1. the RECORDED reasoning criticality wins over the decoy prose" \
  "[ \"\$(json_get '$EG1' reasoningCriticality)\" = 'high' ]"
check "G1. the RECORDED implementation criticality wins over the decoy prose" \
  "[ \"\$(json_get '$EG1' implCriticality)\" = 'medium' ]"
# THE PILLS THEMSELVES, through the REAL board shape function the viewscreen
# uses — asserting estimate.json merely EXISTS would not prove a pill renders.
pills_of() { # <estimate.json> → "cost|reasoning|implementation" labels
  python3 - "$1" "$REPO_ROOT/web" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2])
from lcars_serve import board
est = json.load(open(sys.argv[1]))
p = board.pills_from_estimate(est)
def lab(x):
    return "" if not x else str(x.get("label") or "")
sys.stdout.write("%s|%s|%s" % (lab(p["cost"]), lab(p["reasoning"]),
                               lab(p["implementation"])))
PY
}
PG1="$(pills_of "$EG1")"
check "G1. THE COST PILL RENDERS on the adopted card" \
  "[ -n \"\$(printf '%s' '$PG1' | cut -d'|' -f1)\" ]"
check "G1. the cost pill carries the RECORDED band, not the decoy's \$99" \
  "printf '%s' '$PG1' | cut -d'|' -f1 | grep -q '1.25' && ! printf '%s' '$PG1' | grep -q '99'"
check "G1. THE REASONING pill renders as HIGH" \
  "printf '%s' '$PG1' | cut -d'|' -f2 | grep -qi 'high'"
check "G1. THE IMPLEMENTATION pill renders as MED" \
  "printf '%s' '$PG1' | cut -d'|' -f3 | grep -qi 'med'"

# An envelope with NO estimate fields writes NO estimate.json — an absent fact is
# absent, never a fabricated zero.
IFS="$TAB" read -r repoG2 originG2 <<<"$(new_repo)"
FIXG2="$(new_fixture "$TMPROOT/fixG2")"
mk_body "$FIXG2/issue-71.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-071" "lcars/lcars-20260909-071" main feature copilot null 0)"
printf 'No estimate recorded\n' >"$FIXG2/issue-71.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXG2/issue-71.labels"
adopt_engine "$repoG2" "$FIXG2" 71 "$BOTH_PATH" </dev/null >/dev/null 2>&1
check "G2. an estimate-less envelope invents no estimate.json" \
  "[ ! -f '$(mdir_of "$repoG2" "lcars-20260909-071")/estimate.json' ]"

# A LOCAL estimate.json is never clobbered by a refresh — local richness wins,
# exactly as feedback.md and events.jsonl do.
printf '{ "schemaVersion": 3, "reasoningCriticality": "low", "implCriticality": "low" }\n' \
  >"$(mdir_of "$repoG1" "lcars-20260909-070")/estimate.json"
adopt_engine "$repoG1" "$FIXG1" 70 "$BOTH_PATH" </dev/null >/dev/null 2>&1
check "G3. a re-adopt does NOT overwrite a local estimate.json" \
  "[ \"\$(json_get '$EG1' reasoningCriticality)\" = 'low' ]"
check "G3. and it still PARSES" "json_ok '$EG1'"

# ==========================================================================
# S196 FIX D1 — AND THE PER-STAGE MODEL TIERS SURVIVE IT TOO.
# ==========================================================================
# A5 shipped HALF-CARRIED. The two difficulty pills and the cost pill survived
# adoption; the per-stage MODEL MAP did not, because the envelope recorded the
# criticalities and nothing else. A5's own comment reasoned that a `models`-less
# estimate.json was "harmless downstream" — the tester MEASURED otherwise on two
# genuinely cold clones: laptop A spawned `claude … --model sonnet`, and the
# ADOPTED clone spawned `claude …` with NO `--model` on all three invocations.
# Same mission, two different model policies, and the board's modelMix went to
# `[]` on the laptop that adopted it.
#
# RECORDED, NEVER RE-DERIVED. The tiers ride the envelope as one flat
# `estModels` field, `key=tier` in the estimate's own order. Adopt rebuilds
# `models` FROM THAT — it does not recompute tiers from the criticalities and it
# does not re-scan the "## Estimate" prose, both of which are inferences that
# drift from what the filing laptop actually chose (R9; S147/S156/S188).
est_full_envelope() { # id branch base type engine parent attach reason impl models
  printf '<!-- lcars:handoff v1 {"id":"%s","branch":"%s","base":"%s","type":"%s","engine":"%s","parentIssue":%s,"attachments":%s,"estReasoning":"%s","estImpl":"%s","estModels":"%s"} -->' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}
# models.<key> out of the rebuilt file (json_get is top-level only).
est_model_of() { # <estimate.json> <stage-key>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); m=d.get("models") or {}
sys.stdout.write(str(m.get(sys.argv[2]) or ""))' "$1" "$2" 2>/dev/null
}
G4_MODELS='research=opus,validate=sonnet,plan=opus,planReview=sonnet,implement=opus,verify=sonnet'
IFS="$TAB" read -r repoG4 originG4 <<<"$(new_repo)"
FIXG4="$(new_fixture "$TMPROOT/fixG4")"
mk_body "$FIXG4/issue-72.body" "$PRD_TEXT" \
  "$(est_full_envelope "lcars-20260909-072" "lcars/lcars-20260909-072" main feature claude null 0 \
       high medium "$G4_MODELS")"
printf 'Model tiers carry over\n' >"$FIXG4/issue-72.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXG4/issue-72.labels"
adopt_engine "$repoG4" "$FIXG4" 72 "$BOTH_PATH" </dev/null >/dev/null 2>&1
MG4="$(mdir_of "$repoG4" "lcars-20260909-072")"
EG4="$MG4/estimate.json"
check "G4. adopt writes an estimate.json" "[ -f '$EG4' ]"
check "G4. and it PARSES" "json_ok '$EG4'"
check "G4. the RECORDED per-stage model map is rebuilt (plan)" \
  "[ \"\$(est_model_of '$EG4' plan)\" = 'opus' ]"
check "G4. …and it is the WHOLE map, in the estimate's own stage order" \
  "[ \"\$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))[\"models\"]; sys.stdout.write(\",\".join(\"%s=%s\" % kv for kv in m.items()))' '$EG4')\" = '$G4_MODELS' ]"
check "G4. …the tiers are the RECORDED ones, not one tier smeared over all six" \
  "[ \"\$(est_model_of '$EG4' validate)\" = 'sonnet' ] && [ \"\$(est_model_of '$EG4' implement)\" = 'opus' ]"

# THE BOARD. `modelMix` was `[]` on the adopted card while the same mission
# showed six rows on the laptop that filed it — through the REAL shape function.
mix_len_of() { # <estimate.json> <engine> → row count ("-" for None)
  python3 - "$1" "$2" "$REPO_ROOT/web" <<'PY2'
import json, sys
sys.path.insert(0, sys.argv[3])
from lcars_serve import board
mix = board.model_mix_from_estimate(json.load(open(sys.argv[1])), sys.argv[2])
sys.stdout.write("-" if mix is None else str(len(mix)))
PY2
}
check "G4. THE BOARD'S MODEL MIX RENDERS on the adopted card (was [] / none)" \
  "[ \"\$(mix_len_of '$EG4' claude)\" = '6' ]"

# THE SPAWN — the measurement the tester made, re-armed. Same mission, same
# stage: the adopted clone must hand the worker the tier the filing laptop chose.
shim_reset
spawn_with "$repoG4" "lcars-20260909-072" "$BOTH_PATH"
check "G4. the adopted mission spawns the mission's engine ONCE" \
  "[ \"\$(shim_count claude)\" = '1' ]"
check "G4. THE ADOPTED MISSION NOW SPAWNS WITH --model (it carried none before)" \
  "[ \"\$(shim_model_count claude)\" = '1' ]"
check "G4. …on the RECORDED tier for that stage, not a default" \
  "grep -q -- '--model opus' '$SHIMLOG/claude.log'"
# And every stage key resolves to the tier the estimate recorded — one drive
# through the real resolver, not a re-reading of the file we just wrote.
G4_RESOLVED="$( cd "$repoG4" && env -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL \
  -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
  PATH="$BOTH_PATH:$PY_DIR" bash -c '
    for k in research validate plan planReview implement verify; do
      bash "$1" resolve-stage-model --mission "$2" "$k" 2>/dev/null
    done' _ "$RUN_SH" "lcars-20260909-072" | tr "\n" " " )"
check "G4. every stage resolves to its RECORDED tier through resolve_stage_model" \
  "[ \"\$G4_RESOLVED\" = 'STAGE-MODEL key=research model=opus STAGE-MODEL key=validate model=sonnet STAGE-MODEL key=plan model=opus STAGE-MODEL key=planReview model=sonnet STAGE-MODEL key=implement model=opus STAGE-MODEL key=verify model=sonnet ' ]"

# G5. ADDITIVE WITHIN v1: a body filed BEFORE this fix — the five estimate keys
# and no `estModels` — still adopts, still gets its pills, and carries NO model
# map. An absent fact stays absent; adopt never invents a default tier.
IFS="$TAB" read -r repoG5 originG5 <<<"$(new_repo)"
FIXG5="$(new_fixture "$TMPROOT/fixG5")"
mk_body "$FIXG5/issue-73.body" "$PRD_TEXT" \
  "$(est_envelope "lcars-20260909-073" "lcars/lcars-20260909-073" main feature claude null 0 \
       usd 1.25 4.5 high medium)"
printf 'A pre-fix envelope\n' >"$FIXG5/issue-73.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXG5/issue-73.labels"
rcG5=0
adopt_engine "$repoG5" "$FIXG5" 73 "$BOTH_PATH" </dev/null >/dev/null 2>&1 || rcG5=$?
EG5="$(mdir_of "$repoG5" "lcars-20260909-073")/estimate.json"
check "G5. a PRE-FIX envelope (no estModels) still adopts cleanly" "[ '$rcG5' -eq 0 ]"
check "G5. …its estimate.json PARSES" "json_ok '$EG5'"
check "G5. …the pills still carry (the fix is additive, not a replacement)" \
  "[ \"\$(json_get '$EG5' reasoningCriticality)\" = 'high' ]"
check "G5. …and NO model map is invented for it" \
  "! grep -q '\"models\"' '$EG5'"
check "G5. …so the board shows its graceful note, not an empty table" \
  "[ \"\$(mix_len_of '$EG5' claude)\" = '-' ]"

# ==========================================================================
echo
echo "S197 H — \`--engine-source chosen\`: a HUMAN chose it, and the card says so"
# ==========================================================================
# The board's engine picker can only speak to adopt.sh through argv. Without a
# way to SAY "a human picked this", the captain's deliberate click at the
# viewscreen was written onto the card as a mechanical `converted at adopt` (or
# `kept at adopt`) — the sentence LCARS uses for something nobody was asked
# about. `adopt-chosen` existed but was reachable from exactly one place: the
# ANSWERED PROMPT, which needs a tty AND a config disagreement, and a board
# dispatch has neither.
#
# So the distinction is RECORDED, not inferred. It cannot be inferred: on a
# two-CLI laptop with no config disagreement adopt never prompts and `--engine
# claude` on a claude mission is indistinguishable from a click, so there is
# nothing to infer FROM. One flag carries the fact.
#
# FIXE4/issue 53 is a copilot mission (id lcars-20260909-053); both engines are
# on $PATH as argv-recording shims, so every H case below is zero model spend.
H_MID="lcars-20260909-053"
jlast() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.stdout.write(list(d.keys())[-1] if d else "")' "$1" 2>/dev/null; }

# adopt_src <repo> <PATH> [extra argv…] → the real adopt on issue 53, no tty
adopt_src() {
  local repo="$1" pth="$2"; shift 2
  ( cd "$repo" && env PATH="$pth" GH_FIX="$FIXE4" LCARS_GH_BIN="$GH" \
      LCARS_GIT_BIN="$GIT_ABS" LCARS_GH_USER=capt \
      GH_ASSIGN_STATE="$TMPROOT/assign-h.txt" \
      bash "$SCRIPT" --issue 53 "$@" </dev/null 2>&1 )
}

# --- H1: KEPT-SHAPED but CHOSEN. The flag names the mission's OWN engine ---
# Today this records `adopt-kept` — "the mission's pin carried", a fact about
# the envelope. The truth is that a human read the picker and clicked copilot.
IFS="$TAB" read -r repoH1 originH1 <<<"$(new_repo)"
rcH1=0
outH1="$(adopt_src "$repoH1" "$BOTH_PATH" --engine copilot --engine-source chosen)" || rcH1=$?
sH1="$(state_of "$repoH1" "$H_MID")"
check "H1. \`--engine copilot --engine-source chosen\` adopts cleanly" "[ '$rcH1' -eq 0 ]"
check "H1. state.json PARSES" "json_ok '$sH1'"
check "H1. THE HEADLINE: a human choice is recorded as CHOSEN, not kept" \
  "[ \"\$(json_get '$sH1' engineSource)\" = 'adopt-chosen' ]"
check "H1. …on the engine he picked" "[ \"\$(json_get '$sH1' workerBin)\" = 'copilot' ]"
check "H1. …and engineResolved agrees" \
  "[ \"\$(json_get '$sH1' engineResolved)\" = 'copilot' ]"
check "H1. \`base\` is still the LAST key" "[ \"\$(jlast '$sH1')\" = 'base' ]"
check "H1. the readout tells the captain HE chose it" \
  "printf '%s' \"\$outH1\" | grep -qi 'your choice'"

# --- H2: CONVERTED-SHAPED and CHOSEN --------------------------------------
# Same click, different answer: he picked the engine the mission was NOT filed
# on. It is still a choice, not a mechanical conversion.
IFS="$TAB" read -r repoH2 originH2 <<<"$(new_repo)"
rcH2=0
outH2="$(adopt_src "$repoH2" "$BOTH_PATH" --engine claude --engine-source chosen)" || rcH2=$?
sH2="$(state_of "$repoH2" "$H_MID")"
check "H2. a CHOSEN conversion adopts cleanly" "[ '$rcH2' -eq 0 ]"
check "H2. state.json PARSES" "json_ok '$sH2'"
check "H2. recorded as CHOSEN, not converted" \
  "[ \"\$(json_get '$sH2' engineSource)\" = 'adopt-chosen' ]"
check "H2. …on the engine he picked" "[ \"\$(json_get '$sH2' workerBin)\" = 'claude' ]"
check "H2. \`base\` is still the LAST key" "[ \"\$(jlast '$sH2')\" = 'base' ]"
# THE COUNT. The recorded engine is the one that actually runs.
shim_reset
spawn_with "$repoH2" "$H_MID" "$BOTH_PATH"
check "H2. THE COUNT: the chosen engine ran" "[ \"\$(shim_count claude)\" -ge 1 ]"
check "H2. THE COUNT: the mission's filed engine ran ZERO times" \
  "[ \"\$(shim_count copilot)\" -eq 0 ]"

# --- H3: NO REGRESSION. `--engine` alone is byte-identical to today -------
IFS="$TAB" read -r repoH3 originH3 <<<"$(new_repo)"
adopt_src "$repoH3" "$BOTH_PATH" --engine copilot >/dev/null 2>&1
sH3="$(state_of "$repoH3" "$H_MID")"
check "H3. \`--engine\` naming the mission's engine still records KEPT" \
  "[ \"\$(json_get '$sH3' engineSource)\" = 'adopt-kept' ]"
check "H3. state.json PARSES" "json_ok '$sH3'"
IFS="$TAB" read -r repoH3b originH3b <<<"$(new_repo)"
adopt_src "$repoH3b" "$BOTH_PATH" --engine claude >/dev/null 2>&1
sH3b="$(state_of "$repoH3b" "$H_MID")"
check "H3b. \`--engine\` naming another engine still records CONVERTED" \
  "[ \"\$(json_get '$sH3b' engineSource)\" = 'adopt-converted' ]"
check "H3b. state.json PARSES" "json_ok '$sH3b'"

# --- H4: any other value is REFUSED, and nothing is written ---------------
# A typo must not silently produce a WRONG provenance — the whole value of this
# record is that it is trustworthy. `chosen` is the only thing argv may assert.
for bad in env adopt-chosen CHOSEN "" picked; do
  IFS="$TAB" read -r repoH4 originH4 <<<"$(new_repo)"
  rcH4=0
  outH4="$(adopt_src "$repoH4" "$BOTH_PATH" --engine claude --engine-source "$bad")" || rcH4=$?
  sH4="$(state_of "$repoH4" "$H_MID")"
  check "H4. \`--engine-source '$bad'\` is REFUSED" "[ '$rcH4' -ne 0 ]"
  check "H4. …and nothing was created for '$bad'" "[ ! -e '$sH4' ]"
done

# --- H5: `--engine-source chosen` with NO `--engine` → REFUSED ------------
# THE RULING: refuse, do not ignore. The flag asserts WHO decided; with no
# engine named there is no decision to attribute, and the two alternatives are
# both worse. Ignoring it lets a caller believe a human choice was recorded
# when the mission took adopt's own automatic path; honouring it would stamp
# "a human chose this" on a decision no human made. A caller that sends the
# provenance without the value is broken, and adopt says so instead of
# guessing which half it meant.
IFS="$TAB" read -r repoH5 originH5 <<<"$(new_repo)"
rcH5=0
outH5="$(adopt_src "$repoH5" "$BOTH_PATH" --engine-source chosen)" || rcH5=$?
sH5="$(state_of "$repoH5" "$H_MID")"
check "H5. \`--engine-source chosen\` alone is REFUSED, not silently ignored" \
  "[ '$rcH5' -ne 0 ]"
check "H5. …and nothing was created" "[ ! -e '$sH5' ]"
check "H5. …and the refusal names the flag it needs" \
  "printf '%s' \"\$outH5\" | grep -q -- '--engine'"

# --- H6: --help mentions the new flag -------------------------------------
# A flag a caller cannot discover is a flag that gets guessed at.
outH6="$(bash "$SCRIPT" --help 2>&1)"
printf '%s' "$outH6" > "$TMPROOT/h6-help.txt"
check "H6. \`--help\` documents \`--engine-source\`" \
  "printf '%s' \"\$outH6\" | grep -q -- '--engine-source'"

# ==========================================================================
# BLOCK I (S201) — NUMBER ONE IS DISMISSED BY AN ADOPT, AND OFFERED AT VERIFY
# ==========================================================================
# TWO RULES, and they are deliberately separate:
#
#   THE DISMISSAL IS UNCONDITIONAL. Engagement is a fact about ONE laptop — a
#   worker running there, a pid in that mission directory. A `numberOne` key
#   carried across on the REFRESH path (the one that copies the existing
#   state.json rather than rebuilding it) would badge a mission whose officer is
#   not aboard, and LOCK its controls with a stand-down command that cannot
#   reach the process it names. adopt deletes it, and SAYS it did.
#
#   THE OFFER IS THIS REPO'S OWN, and it is asked only where there is something
#   to answer about: `numberOne.enabled` in THIS config and a mission at VERIFY.
#   It ENGAGES NOTHING and it RECORDS NOTHING — because taking the conn is the
#   driver's act at a gate and a second way in is the duplication this round
#   exists to prevent. NO TTY IS `no`, the same posture the engine picker one
#   section up takes.
#
#   AND `no` IS NOT A DURABLE OPT-OUT (fix round 1, D2 of the adopt half).
#   Declining at the prompt means "not engaged NOW", which is already the
#   state a mission is born in. Writing `numberOne: {optOut: true}` made every
#   SILENT adopt — the scripted one, the board's, the one with no tty — opt
#   that mission out of a later repo-wide `lcars xo on` for good, a durable
#   answer to a question nobody was asked. The key stays ABSENT, exactly as a
#   fresh adopt leaves it (the additive-key rule, S109): absent is the honest
#   record of "nothing was decided here".
echo
echo "  ── I: Number One, dismissed and offered (S201) ──"

xo_status_of() { # <state.json> → the recorded numberOne.status, or empty
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); x=d.get("numberOne")
sys.stdout.write(x.get("status","") if isinstance(x,dict) else "")' "$1" 2>/dev/null
}
xo_optout_of() { # <state.json> → "True"/"" — the recorded per-mission opt-out
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); x=d.get("numberOne")
sys.stdout.write(str(x.get("optOut")) if isinstance(x,dict) and x.get("optOut") else "")' "$1" 2>/dev/null
}

# --- I1: the REFRESH path deletes an engaged numberOne and reports it ------
IFS="$TAB" read -r repoI1 originI1 <<<"$(new_repo)"
seed_branch "$originI1" "lcars/$MID"
# ASSIGNED to capt, so the dismissal line has an owner to NAME. (An unassigned
# mission still reports the dismissal; it just has no handle to put in front of
# it, and inventing one would be worse than the honest fallback.)
ASSIGN_I1="$TMPROOT/assignI1.txt"; printf 'capt\n' >"$ASSIGN_I1"
( cd "$repoI1" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_I1" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >/dev/null 2>&1 )
sI1="$(state_of "$repoI1" "$MID")"
# …now Number One takes the conn HERE, the way `lcars xo` writes it: one line,
# at the TOP of the object (the S189 rule the state writers all follow).
python3 - "$sI1" <<'PYX'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(True)
lines.insert(1, '  "numberOne": {"status": "engaged", "engine": "copilot"},\n')
open(p, "w").writelines(lines)
PYX
check "I1. the fixture really plants an engaged Number One" \
  "[ \"\$(xo_status_of '$sI1')\" = 'engaged' ]"
# …and the SAME mission is adopted again (the refresh path).
rcI1=0
( cd "$repoI1" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_I1" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >outI1.txt 2>&1 ) || rcI1=$?
check "I1. the refresh adopt exits 0" "[ '$rcI1' -eq 0 ]"
check "I1. state.json PARSES after the dismissal" "json_ok '$sI1'"
check "I1. the engaged Number One is GONE from the rebuilt state" \
  "[ -z \"\$(xo_status_of '$sI1')\" ]"
check "I1. …and there is no numberOne key at all" "! json_has '$sI1' numberOne"
check "I1. the readout SAYS the Number One was dismissed" \
  "grep -q \"Number One was dismissed by this adopt\" '$repoI1/outI1.txt'"
check "I1. the dismissal names whose officer it was" \
  "grep -q \"capt's Number One was dismissed\" '$repoI1/outI1.txt'"

# --- I2: nothing is said when there was no Number One ----------------------
IFS="$TAB" read -r repoI2 originI2 <<<"$(new_repo)"
seed_branch "$originI2" "lcars/$MID"
ASSIGN_I2="$TMPROOT/assignI2.txt"; : >"$ASSIGN_I2"
( cd "$repoI2" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_I2" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >outI2.txt 2>&1 )
sI2="$(state_of "$repoI2" "$MID")"
check "I2. a FRESH adopt records no numberOne key" "! json_has '$sI2' numberOne"
check "I2. …and says nothing about a dismissal" \
  "! grep -q 'Number One' '$repoI2/outI2.txt'"
check "I2. …and asks nothing, because this repo has not enabled it" \
  "! grep -qi 'Engage Number One' '$repoI2/outI2.txt'"

# --- I3: the OFFER, at Verify, with the repo's toggle ON and no tty --------
# NO TTY IS `no`, AND `no` WRITES NOTHING. A silent adopt must leave state.json
# exactly as a fresh adopt leaves it — no `numberOne` key at all — because the
# alternative (a recorded opt-out) is a durable answer given on the captain's
# behalf by a script he never sat in front of.
IFS="$TAB" read -r repoI3 originI3 <<<"$(new_repo)"
seed_branch "$originI3" "lcars/$MID"
mkdir -p "$repoI3/.git/lcars"
printf '{\n  "model": "claude-sonnet",\n  "numberOne": {"enabled": true, "engine": "copilot"}\n}\n' \
  >"$repoI3/.git/lcars/config.json"
ASSIGN_I3="$TMPROOT/assignI3.txt"; : >"$ASSIGN_I3"
( cd "$repoI3" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_I3" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 >outI3.txt 2>&1 </dev/null )
sI3="$(state_of "$repoI3" "$MID")"
check "I3. state.json PARSES after a declined offer" "json_ok '$sI3'"
check "I3. no tty ⇒ NOT engaged, and NOTHING is recorded (the key is ABSENT)" \
  "! json_has '$sI3' numberOne"
check "I3. …not even an opt-out, which would outlive this adopt" \
  "[ -z \"\$(xo_optout_of '$sI3')\" ]"
check "I3. …and the readout still DISCLOSES it, with the way back" \
  "grep -q 'lcars xo on' '$repoI3/outI3.txt'"

# --- I3b: `--number-one no` is the same answer, written down the same way --
# The explicit flag and the silent default must agree: both mean "not now",
# and neither is a durable opt-out.
IFS="$TAB" read -r repoI3b originI3b <<<"$(new_repo)"
seed_branch "$originI3b" "lcars/$MID"
mkdir -p "$repoI3b/.git/lcars"
printf '{\n  "model": "claude-sonnet",\n  "numberOne": {"enabled": true, "engine": "copilot"}\n}\n' \
  >"$repoI3b/.git/lcars/config.json"
ASSIGN_I3B="$TMPROOT/assignI3b.txt"; : >"$ASSIGN_I3B"
( cd "$repoI3b" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_I3B" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 --number-one no \
    >outI3b.txt 2>&1 </dev/null )
sI3b="$(state_of "$repoI3b" "$MID")"
check "I3b. \`--number-one no\` records no numberOne key either" \
  "! json_has '$sI3b' numberOne"
check "I3b. …and state.json PARSES" "json_ok '$sI3b'"

# --- I4: the OFFER answered YES, at a tty ---------------------------------
IFS="$TAB" read -r repoI4 originI4 <<<"$(new_repo)"
seed_branch "$originI4" "lcars/$MID"
mkdir -p "$repoI4/.git/lcars"
printf '{\n  "model": "claude-sonnet",\n  "numberOne": {"enabled": true, "engine": "copilot"}\n}\n' \
  >"$repoI4/.git/lcars/config.json"
ASSIGN_I4="$TMPROOT/assignI4.txt"; : >"$ASSIGN_I4"
( cd "$repoI4" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_I4" LCARS_GH_USER=capt \
    LCARS_ASSUME_TTY=1 LCARS_GH_BIN="$GH" \
    bash "$SCRIPT" --issue 42 >outI4.txt 2>&1 <<<"y" )
sI4="$(state_of "$repoI4" "$MID")"
check "I4. the question is ASKED at a tty" \
  "grep -qi 'Engage Number One on this mission now' '$repoI4/outI4.txt'"
check "I4. …and the question NAMES NO PRICE" \
  "! grep -Eqi 'free|billed|cost' '$repoI4/outI4.txt'"
check "I4. yes leaves the mission IN SCOPE — no opt-out is recorded" \
  "[ -z \"\$(xo_optout_of '$sI4')\" ]"
check "I4. …and it ENGAGES nothing (the driver does that at a gate)" \
  "[ -z \"\$(xo_status_of '$sI4')\" ]"
check "I4. state.json PARSES" "json_ok '$sI4'"

# --- I5: the flag answers for a caller with no tty (the board's checkbox) --
IFS="$TAB" read -r repoI5 originI5 <<<"$(new_repo)"
seed_branch "$originI5" "lcars/$MID"
mkdir -p "$repoI5/.git/lcars"
printf '{\n  "numberOne": {"enabled": true, "engine": "copilot"}\n}\n' \
  >"$repoI5/.git/lcars/config.json"
ASSIGN_I5="$TMPROOT/assignI5.txt"; : >"$ASSIGN_I5"
( cd "$repoI5" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_I5" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 --number-one yes \
    >outI5.txt 2>&1 </dev/null )
sI5="$(state_of "$repoI5" "$MID")"
check "I5. \`--number-one yes\` keeps the mission in scope with no tty" \
  "[ -z \"\$(xo_optout_of '$sI5')\" ]"
check "I5. …and nothing was asked" \
  "! grep -qi 'Engage Number One on this mission now' '$repoI5/outI5.txt'"
IFS="$TAB" read -r repoI6 originI6 <<<"$(new_repo)"
rcI6=0
outI6="$( cd "$repoI6" && GH_FIX="$FIXV" GH_ASSIGN_STATE="$ASSIGN_I5" LCARS_GH_USER=capt \
    LCARS_GH_BIN="$GH" bash "$SCRIPT" --issue 42 --number-one maybe 2>&1 )" || rcI6=$?
check "I5. any other value is REFUSED, never guessed at" "[ '$rcI6' -ne 0 ]"
check "I5. …and nothing was created" "[ ! -e \"\$(state_of '$repoI6' '$MID')\" ]"

# --- I6: --help documents the flag ----------------------------------------
outI7="$(bash "$SCRIPT" --help 2>&1)"
check "I6. \`--help\` documents \`--number-one\`" \
  "printf '%s' \"\$outI7\" | grep -q -- '--number-one'"

# ==========================================================================
echo
echo "S207 item 3 — AN ADOPTED CLONE IS STAMPED, SO IT STOPS NAGGING"
# ==========================================================================
# adopt seeds config.json (S196 A4) through init's own detectors, but the one
# key it did NOT seed was `lcarsVersion` — so `lcars version`'s REPO_PREDATES
# verdict fired on a repo LCARS had itself configured minutes earlier, and every
# verb printed "⚠ this repo predates LCARS versioning — run `lcars update`."
# until the captain ran an update he did not need. The stamp logic is
# update.sh's (`lcars_running_version`), reused, never re-derived: the running
# clone's VERSION file, with LCARS_VERSION as the test seam.
IFS="$TAB" read -r repoV1 originV1 <<<"$(new_repo)"
rm -f "$repoV1/.git/lcars/config.json"          # the cold clone, as in F1
FIXV1="$(new_fixture "$TMPROOT/fixV1")"
mk_body "$FIXV1/issue-63.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-063" "lcars/lcars-20260909-063" main feature claude null 0)"
printf 'Unstamped clone\n' >"$FIXV1/issue-63.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXV1/issue-63.labels"
adopt_engine "$repoV1" "$FIXV1" 63 "$BOTH_PATH" LCARS_VERSION=2026.9.99 \
  </dev/null >/dev/null 2>&1
CFGV1="$repoV1/.git/lcars/config.json"
check "V1. the seeded config carries a version stamp" "json_has '$CFGV1' lcarsVersion"
check "V1. and it is the RUNNING version, not a guess" \
  "[ \"\$(json_get '$CFGV1' lcarsVersion)\" = '2026.9.99' ]"
check "V1. the config still PARSES" "json_ok '$CFGV1'"
# The verdict the stamp exists to answer: version.sh reads config.json and must
# no longer say the repo predates versioning.
outV1="$(cd "$repoV1" && LCARS_VERSION=2026.9.99 bash "$REPO_ROOT/skills/lcars-version/version.sh" 2>&1)"
check "V1. \`lcars version\` no longer says the repo PREDATES versioning" \
  "! printf '%s' \"\$outV1\" | grep -qi 'predates'"
check "V1. it reads the stamp as CURRENT" \
  "printf '%s' \"\$outV1\" | grep -q 'verdict:.*current'"

# THE REFRESH PATH: adopting the SAME issue again re-enters with a config that
# already exists, and the stamp must survive it (the merge preserves a key it is
# given; an absent key is DELETED, which is how cloneId was lost in S196).
adopt_engine "$repoV1" "$FIXV1" 63 "$BOTH_PATH" LCARS_VERSION=2026.9.99 \
  </dev/null >/dev/null 2>&1
check "V2. a REFRESH adopt keeps the stamp" \
  "[ \"\$(json_get '$CFGV1' lcarsVersion)\" = '2026.9.99' ]"
check "V2. and the config still PARSES" "json_ok '$CFGV1'"

# A repo that already had a config keeps ITS stamp — adopt does not restamp a
# repo it did not configure (that would silence a TRUE "needs lcars update").
IFS="$TAB" read -r repoV3 originV3 <<<"$(new_repo)"
cat >"$repoV3/.git/lcars/config.json" <<'CFG'
{
  "model": "claude-sonnet",
  "lcarsVersion": "2026.1.1"
}
CFG
FIXV3="$(new_fixture "$TMPROOT/fixV3")"
mk_body "$FIXV3/issue-64.body" "$PRD_TEXT" \
  "$(envelope "lcars-20260909-064" "lcars/lcars-20260909-064" main feature claude null 0)"
printf 'Older stamped clone\n' >"$FIXV3/issue-64.title"
printf 'lcars:mission\nlcars:align\n' >"$FIXV3/issue-64.labels"
adopt_engine "$repoV3" "$FIXV3" 64 "$BOTH_PATH" LCARS_VERSION=2026.9.99 \
  </dev/null >/dev/null 2>&1
check "V3. an EXISTING stamp is left alone (adopt is not an update)" \
  "[ \"\$(json_get '$repoV3/.git/lcars/config.json' lcarsVersion)\" = '2026.1.1' ]"

# ==========================================================================
echo
printf 'lcars adopt: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
