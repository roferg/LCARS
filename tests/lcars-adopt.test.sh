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
printf 'lcars adopt: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
