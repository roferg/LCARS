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

# Compare the two paths PHYSICALLY and case-INSENSITIVELY. The old check was a
# case-SENSITIVE `case "$target" in "$REPO"/*)` string glob, and that is wrong on
# this machine: APFS is case-insensitive but `pwd -P` preserves the case you
# TYPED, so the install symlink reads /Users/…/Projects/LCARS/… while
# `LCARS_REPO=~/Projects/lcars` (or a buddy invoked through a lowercase path)
# resolves to /Users/…/Projects/lcars — the SAME directory, reported as STALE.
# This is the one line a captain runs buddy in order to trust, so a false STALE
# sends them to re-install a perfectly good checkout, or teaches them to ignore
# the brief. Resolving both sides through `cd … && pwd -P` also collapses /tmp vs
# /private/tmp and any other symlinked ancestor; lowercasing then makes LCARS vs
# lcars read IN SYNC while a genuinely different checkout still reads STALE.
phys() { # path -> its physical path when it exists, else the path unchanged
  if [ -d "$1" ]; then (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
  else printf '%s\n' "$1"; fi
}
lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }

# Judge the verdict on EVERY installed skill, not one probe symlink. The old
# check read `lcars-run` ALONE, so a PARTIAL install — lcars-run linked here
# while the rest still point at another checkout — printed a confident "in sync".
# That is the one line a captain runs buddy in order to trust before they start
# editing, and half a checkout running the old code is worse than all of it
# running the old code, because only some of their fixes take effect. So: IN SYNC
# only when every installed skill AGREES; when they disagree, say so and NAME one.
#
# DIRECTION IS ONLY HALF THE QUESTION. A verdict that asks only "does what IS
# here point at me?" is silent about what is NOT here: a dest holding a single,
# correctly-linked lcars-run read `in sync. (1 skill(s) checked)` while seventeen
# skills were missing — which is the ledgered defect in its original words ("a
# partial install where lcars-run is linked but others are not reads as fully in
# sync"). The count was printed but compared to NOTHING, so it could not falsify
# anything. The installed set is therefore measured against the skills this
# checkout actually SHIPS, and IN SYNC needs direction AND completeness.
#
# The glob is `lcars*`, not `lcars-*`: the bare one-word `lcars` skill — the verb
# the captain uses most — was globbed straight out, so seventeen lcars-* links
# aimed here plus a bare `lcars` aimed at a DIFFERENT checkout still read
# "in sync. (17 skill(s) checked)" with eighteen skills installed.

# What this checkout SHIPS — the denominator. Every directory under skills/ is a
# skill, the bare `lcars` included.
shipped=""
n_shipped=0
for d in "$REPO"/skills/*/; do
  [ -d "$d" ] || continue
  shipped="$shipped $(basename "$d")"
  n_shipped=$((n_shipped + 1))
done

r_cmp="$(lower "$(phys "$REPO")")"
n_match=0 n_other=0 n_notlink=0
first_other="" first_other_target="" first_notlink=""
installed_names=""
for entry in "$SKILLS_DEST"/lcars*; do
  # A broken symlink fails -e but passes -L, and is still an installed skill.
  [ -L "$entry" ] || [ -e "$entry" ] || continue
  name="$(basename "$entry")"
  if [ ! -L "$entry" ]; then
    n_notlink=$((n_notlink + 1))
    [ -n "$first_notlink" ] || first_notlink="$name"
    # It occupies the slot, so it counts as PRESENT for completeness — the
    # complaint about it is direction (it is not a link at all), not absence.
    installed_names="$installed_names $name"
    continue
  fi
  installed_names="$installed_names $name"
  target="$(readlink "$entry")"
  # A relative symlink target is relative to the LINK's directory, not our cwd.
  case "$target" in /*) ;; *) target="$SKILLS_DEST/$target" ;; esac
  t_cmp="$(lower "$(phys "$target")")"
  if [ "$t_cmp" = "$r_cmp" ] || [ "${t_cmp#"$r_cmp"/}" != "$t_cmp" ]; then
    n_match=$((n_match + 1))
  else
    n_other=$((n_other + 1))
    [ -n "$first_other" ] || { first_other="$name"; first_other_target="$target"; }
  fi
done
n_checked=$((n_match + n_other + n_notlink))

# COMPLETENESS: which shipped skills have no slot in the dest at all.
n_missing=0
first_missing=""
for name in $shipped; do
  case " $installed_names " in
    *" $name "*) ;;
    *) n_missing=$((n_missing + 1)); [ -n "$first_missing" ] || first_missing="$name" ;;
  esac
done

if [ "$n_checked" -eq 0 ]; then
  echo "  ⚠ LCARS skills are not installed here — run \`./install.sh\` in $REPO."
elif [ "$n_other" -eq 0 ] && [ "$n_notlink" -eq 0 ] && [ "$n_missing" -eq 0 ]; then
  # Unanimous AND complete. The count is printed as a FRACTION so a reader can
  # falsify "in sync" — a verdict from one symlink and a verdict from all
  # eighteen used to read identically.
  echo "  ✓ installed skills point at THIS checkout — in sync. ($n_checked of $n_shipped skills installed)"
elif [ "$n_other" -eq 0 ] && [ "$n_notlink" -eq 0 ]; then
  # Every link that IS here is aimed correctly — but skills are MISSING, so this
  # is not a synced install: the absent ones are not running this checkout's code
  # at all, and if they are installed elsewhere on this machine they are running
  # that checkout's.
  echo "  ⚠ installed skills point at THIS checkout, but the install is INCOMPLETE — only $n_checked of $n_shipped skills installed."
  echo "    $n_missing missing, e.g. $first_missing."
  echo "    Run \`./install.sh\` in $REPO so every skill is linked."
elif [ "$n_match" -eq 0 ] && [ "$n_other" -eq 0 ]; then
  echo "  ⚠ $SKILLS_DEST/$first_notlink exists but is not a symlink — run \`./install.sh\` in $REPO to (re)link."
elif [ "$n_match" -eq 0 ] && [ "$n_notlink" -eq 0 ]; then
  echo "  ⚠ installed skills point ELSEWHERE ($first_other_target) — they are STALE."
  echo "    Run \`./install.sh\` in $REPO so your fixes are what runs."
else
  echo "  ⚠ installed skills DISAGREE — this is a PARTIAL install, not a synced one."
  detail="$n_match point at THIS checkout"
  [ "$n_other" -gt 0 ] && detail="$detail, $n_other point elsewhere"
  [ "$n_notlink" -gt 0 ] && detail="$detail, $n_notlink are not symlinks"
  echo "    of $n_checked skill(s) checked: $detail."
  [ "$n_missing" -gt 0 ] && \
    echo "    and only $n_checked of $n_shipped skills are installed at all ($n_missing missing, e.g. $first_missing)."
  [ -n "$first_other" ] && echo "    e.g. $first_other -> $first_other_target"
  [ -n "$first_notlink" ] && echo "    e.g. $first_notlink is not a symlink"
  echo "    Only SOME of your fixes would take effect. Run \`./install.sh\` in $REPO."
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
echo "HOW A FIX IS RUN: this skill's SKILL.md § 2, which follows ~/.claude/skills/lcars-buddy/ORCHESTRATION.md."
hr
exit 0
