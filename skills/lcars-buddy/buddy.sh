#!/usr/bin/env bash
#
# lcars buddy — the diagnostic collector behind the global "spin up an LCARS
# debugging buddy anywhere" skill.
#
# The captain is OFF in some other repo (groutwork, a game, …) driving a Mission,
# and LCARS itself misbehaves. They run `lcars buddy` right there. This script
# prints ONE brief that orients a fresh debugging session:
#
#   1. WHERE the LCARS source lives + its git state — the code we will fix.
#   2. Whether the INSTALLED skills actually point at that checkout — so a fix
#      the captain makes is the code that actually runs (the #1 live-debug trap).
#   3. The CURRENT repo's Mission state — config + each mission's stage, status,
#      and the last few events (the failing breadcrumb that triggered this).
#   4. Pointers to the source-of-truth docs + the build contract the buddy obeys.
#
# It is READ-ONLY: it scans and prints, changing nothing. SKILL.md tells the
# buddy what to do with the brief.
#
# Dependencies are env-injected so tests can stub them and never touch the real
# home dirs:
#   LCARS_REPO          the LCARS checkout to debug (default: resolved from this
#                       script's real path — works through the install symlink)
#   GIT_BIN             git binary                  (default: git)
#   LCARS_BUDDY_CWD     repo to inspect for missions (default: $PWD)
#   LCARS_SKILLS_DEST   installed Claude skills dir  (default: ~/.claude/skills)
set -uo pipefail

GIT_BIN="${GIT_BIN:-git}"
CWD="${LCARS_BUDDY_CWD:-$PWD}"
SKILLS_DEST="${LCARS_SKILLS_DEST:-$HOME/.claude/skills}"

# --- locate the LCARS checkout --------------------------------------------
# This script ships at <repo>/skills/lcars-buddy/buddy.sh but is invoked through
# the install symlink (~/.claude/skills/lcars-buddy -> <repo>/skills/lcars-buddy).
# `pwd -P` resolves that symlinked dir to its PHYSICAL path, so ../.. lands on
# the real checkout no matter how it was called. An explicit LCARS_REPO wins.
SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
DEFAULT_REPO="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd -P)"
REPO="${LCARS_REPO:-$DEFAULT_REPO}"

# Validate it really is an LCARS checkout before we point a buddy at it.
is_lcars_checkout() { [ -f "$1/vision.md" ] && [ -f "$1/install.sh" ] && [ -d "$1/skills" ]; }
if ! is_lcars_checkout "$REPO"; then
  {
    echo "lcars buddy: '$REPO' is not an LCARS checkout (no vision.md / install.sh / skills/)."
    echo "  Set LCARS_REPO to your LCARS clone, e.g.:"
    echo "      LCARS_REPO=~/Projects/LCARS lcars buddy"
  } >&2
  exit 1
fi

# --- tiny JSON readers (mirror status.sh) ---------------------------------
# json_str reads the string body up to the closing quote, treating a
# backslash-escaped quote (\") as part of the value rather than its end, and
# decodes the common JSON escapes on the way out. This is not a corner case for
# buddy: S148 makes every testCommand LCARS seeds QUOTE its $LCARS_TESTS_DIR
# scope, so a correctly-configured config.json ALWAYS carries \" — and the old
# naive [^"]* sed reader printed a TRUNCATED command, i.e. it misreported the
# one value a captain runs buddy to check. A mission title containing a quote
# truncated the same way. POSIX awk only (no jq, no GNU-isms) so it runs on BSD
# awk; kept byte-identical to skills/lcars-status/status.sh so the two readers
# can never disagree — which is what this comment claimed all along.
json_str() { # file key
  [ -f "$1" ] || return 0
  awk -v k="$2" '
    done { next }
    {
      tok = "\"" k "\""
      p = index($0, tok)
      if (p == 0) next
      rest = substr($0, p + length(tok))
      if (match(rest, /^[ \t]*:[ \t]*"/) == 0) next   # not "key": "…", keep looking
      rest = substr(rest, RLENGTH + 1)                # now at the value body
      out = ""; i = 1; n = length(rest)
      while (i <= n) {
        c = substr(rest, i, 1)
        if (c == "\\") {                              # an escape sequence
          e = substr(rest, i + 1, 1)
          if      (e == "n") out = out "\n"
          else if (e == "t") out = out "\t"
          else               out = out e              # \" \\ \/ … → the bare char
          i += 2; continue
        }
        if (c == "\"") break                          # unescaped quote ends the value
        out = out c; i += 1
      }
      print out; done = 1
    }
  ' "$1" 2>/dev/null
}
json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" 2>/dev/null | head -1; }

hr() { printf -- '────────────────────────────────────────────────────────\n'; }

# ==========================================================================
# 1) THE LCARS SOURCE — what we will read and fix
# ==========================================================================
hr
echo "LCARS BUDDY — ride along, get the detail, live-debug if it comes to that"
hr
echo "LCARS REPO: $REPO"
branch="$("$GIT_BIN" -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
head="$("$GIT_BIN" -C "$REPO" rev-parse HEAD 2>/dev/null)"
echo "  branch: ${branch:-<unknown>}    HEAD: ${head:0:12}"
dirty="$("$GIT_BIN" -C "$REPO" status --short 2>/dev/null)"
if [ -n "$dirty" ]; then
  echo "  working tree has UNCOMMITTED changes:"
  printf '%s\n' "$dirty" | sed 's/^/    /'
else
  echo "  working tree: clean"
fi
echo "  recent commits:"
"$GIT_BIN" -C "$REPO" log --oneline -3 2>/dev/null | sed 's/^/    /'

# ==========================================================================
# 2) INSTALL SYNC — is the code you'll edit the code that actually runs?
# ==========================================================================
echo
echo "INSTALL SYNC ($SKILLS_DEST):"
probe="$SKILLS_DEST/lcars-run"
if [ -L "$probe" ]; then
  target="$(readlink "$probe")"
  case "$target" in
    "$REPO"/*) echo "  ✓ installed skills point at THIS checkout — in sync." ;;
    *)         echo "  ⚠ installed skills point ELSEWHERE ($target) — they are STALE."
               echo "    Run \`./install.sh\` in $REPO so your fixes are what runs." ;;
  esac
elif [ -e "$probe" ]; then
  echo "  ⚠ $probe exists but is not a symlink — run \`./install.sh\` in $REPO to (re)link."
else
  echo "  ⚠ LCARS skills are not installed here — run \`./install.sh\` in $REPO."
fi

# ==========================================================================
# 3) THE CURRENT REPO — the Mission(s) that triggered this
# ==========================================================================
echo
echo "CURRENT REPO: $CWD"
lcars_dir="$CWD/.git/lcars"
missions_dir="$lcars_dir/missions"
if [ ! -d "$missions_dir" ]; then
  echo "  (not LCARS-initialized — no .git/lcars/missions/ here. That's fine: you"
  echo "   can still debug & fix the LCARS source above. Run \`lcars init\` to drive"
  echo "   a Mission from this repo.)"
else
  cfg="$lcars_dir/config.json"
  if [ -f "$cfg" ]; then
    echo "  config:"
    echo "    testCommand:          $(json_str "$cfg" testCommand)"
    echo "    worktreeSetupCommand: $(json_str "$cfg" worktreeSetupCommand)"
    echo "    model: $(json_str "$cfg" model)    workerBin: $(json_str "$cfg" workerBin)"
  fi
  found=0
  for s in "$missions_dir"/*/state.json; do
    [ -f "$s" ] || continue
    found=1
    d="$(dirname "$s")"
    id="$(json_str "$s" id)"
    stage="$(json_str "$s" stage)"
    title="$(json_str "$s" title)"
    paused="$(json_raw "$s" paused)"
    awaiting="$(json_raw "$s" awaitingHuman)"
    worker="$(json_str "$s" workerBin)"
    status=""
    [ "$paused" = "true" ] && status="$status ⏸ paused"
    [ "$awaiting" = "true" ] && status="$status ⚠ awaiting-human"
    echo
    echo "  MISSION $id  [stage: $stage]$status"
    [ -n "$title" ] && echo "    title:  $title"
    [ -n "$worker" ] && echo "    engine: $worker"
    if [ -f "$d/events.jsonl" ]; then
      echo "    last events:"
      tail -5 "$d/events.jsonl" 2>/dev/null | sed 's/^/      /'
    fi
  done
  [ "$found" -eq 1 ] || echo "  (initialized, but no missions filed yet.)"
fi

# ==========================================================================
# 4) THE CONTRACT — how the buddy works on LCARS
# ==========================================================================
echo
echo "READ FIRST (source of truth, in $REPO):"
echo "  - CLAUDE.md   the build contract: skills live in skills/<name>/, TDD,"
echo "                ./install.sh symlinks them, fast scoped tests/<name>.test.sh."
echo "  - vision.md   the product design.    - CONTEXT.md  the domain glossary."
echo
echo "BUDDY RULES (carry the LCARS contract into this foreign repo):"
echo "  • Author fixes in $REPO/skills/<name>/ (NEVER ~/.claude) + tests/<name>.test.sh."
echo "  • TDD: failing test first. Verify with the FAST scoped tests/<name>.test.sh."
echo "  • Do NOT run the heavy tests/lcars-run.test.sh or full tests/run.sh to completion."
echo "  • After any change run \`./install.sh\` so the fix is what actually runs."
echo "  • Reproduce off the breadcrumb above, then read the relevant skill's .sh."
hr
exit 0
