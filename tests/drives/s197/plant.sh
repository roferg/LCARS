#!/usr/bin/env bash
#
# tests/drives/s197/plant.sh — rebuild the S197 buddy-orchestrator proof rig.
#
# Builds the sandbox the S197 tester drove: a throwaway LCARS clone carrying THE
# CODE UNDER TEST on a CLEAN `main` (buddy's pre-flight refuses a dirty tree or a
# non-main branch), a throwaway install with ALL FIVE install destinations
# redirected, a foreign fixture repo with one planted mission whose events.jsonl
# ends in a breadcrumb, and the one-line defect that breadcrumb describes.
#
# WHAT "THE CODE UNDER TEST" MEANS, AND WHY IT IS NOT OBVIOUS.
# The first version of this rig checked the clone out on `main` and then copied
# $SRC's UNCOMMITTED files over it. That was right while the work was dirty. The
# moment the work was COMMITTED to a branch it became silently WRONG: the clone
# went back to `main` (ff1bb68) and carried none of the branch — no
# ORCHESTRATION.md, no LCARS_INSTALL_PREFIX — so re-running the rig to "verify
# the PR" tested the OLD code and reported a confident green. A fresh tester hit
# exactly that. So: clone $SRC's actual HEAD, keep copying any dirty files on top
# (both states work), and then PROVE it landed — see THE GUARD below. A proof rig
# that can silently test the wrong code is worse than no rig at all.
#
# WHY ALL FIVE DESTINATIONS: install.sh has five, and four default into $HOME
# (LCARS_BIN_DEST -> ~/.local/bin, LCARS_COPILOT_PLUGINS_DIR -> ~/.copilot/...,
# LCARS_COPILOT_CONFIG -> ~/.copilot/config.json, LCARS_VERSION_STAMP ->
# ~/.claude/lcars-version-check). Setting only LCARS_SKILLS_DEST repoints the
# captain's REAL launchers and Copilot plugin at the throwaway clone. This
# happened on 2026-09-11 and had to be repaired.
#
#   usage: SRC=<lcars checkout to clone> SANDBOX=<empty dir> bash plant.sh
#
set -euo pipefail
SRC="${SRC:?set SRC to the LCARS checkout (or worktree) to clone}"
SANDBOX="${SANDBOX:?set SANDBOX to a scratch dir}"
mkdir -p "$SANDBOX"

CLONE="$SANDBOX/s197-lcars"
SKILLS="$SANDBOX/s197-skills"
FIXTURE="$SANDBOX/s197-fixture"
SHIM="$SANDBOX/shim"

# --- refusing PATH shims for BOTH worker CLIs (a shim, never an env var:
# --- S159 measured an env var losing to a persisted state.json workerBin) ----
mkdir -p "$SHIM"
for cli in claude copilot; do
  cat > "$SHIM/$cli" <<SH
#!/bin/sh
echo "\$(date +%s) $cli \$*" >> "$SHIM/invocations.log"
echo "REFUSED: worker CLIs are shimmed (zero-spend drive)." >&2
exit 97
SH
  chmod +x "$SHIM/$cli"
done
: > "$SHIM/invocations.log"
export PATH="$SHIM:$PATH"

# --- gh stub (lcars init creates 16 labels) ---------------------------------
mkdir -p "$SANDBOX/stub"
cat > "$SANDBOX/stub/gh" <<'SH'
#!/usr/bin/env bash
echo "$(date +%s) gh $*" >> "$(dirname "$0")/gh-invocations.log"
case "$1" in
  auth) echo "github.com: logged in as s197-fixture" ;;
  repo) echo '{"name":"s197-fixture","owner":{"login":"s197"}}' ;;
  *)    exit 0 ;;
esac
SH
chmod +x "$SANDBOX/stub/gh"

# --- the clone: THE CODE UNDER TEST, on a CLEAN `main` ----------------------
# $SRC's HEAD is the code under test, whatever branch it sits on. Check that sha
# out as the clone's own `main` (buddy refuses a non-`main` checkout, and that
# refusal is itself under test), then copy any UNCOMMITTED files over it — a
# plain `git clone` carries only committed content, so a dirty WIP would not come
# along. Both states therefore work: committed on a branch, or dirty on main.
SRC_SHA="$(git -C "$SRC" rev-parse HEAD)"
SRC_BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
rm -rf "$CLONE"
git clone -q "$SRC" "$CLONE"
# -B so it works whether or not the clone already has a `main`; the sha, not the
# branch name, because a detached HEAD has no branch to name.
git -C "$CLONE" checkout -q -B main "$SRC_SHA" 2>/dev/null \
  || git -C "$CLONE" checkout -q -B main "origin/$SRC_BRANCH"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -e "$SRC/$f" ] && { mkdir -p "$CLONE/$(dirname "$f")"; cp "$SRC/$f" "$CLONE/$f"; }
done < <(git -C "$SRC" status --porcelain | sed 's/^...//')

# --- THE PLANTED DEFECT: one line, in a field the brief and `lcars status`
# --- both render. Pre-fix it prints a bare `42` where the board says `#42`.
perl -0pi -e 's/\*\)       issue_disp="#\$issue" ;;/*)       issue_disp="\$issue" ;;/' \
  "$CLONE/skills/lcars-status/status.sh"
grep -q 'issue_disp="\$issue"' "$CLONE/skills/lcars-status/status.sh" \
  || { echo "plant.sh: the defect did not apply — status.sh has drifted" >&2; exit 1; }

git -C "$CLONE" add -A
git -C "$CLONE" -c user.name="S197 Rig" -c user.email="rig@example.invalid" \
  commit -q -m "sandbox baseline: the code under test + one planted defect in lcars-status"

# --- THE GUARD: prove the sandbox carries the CODE UNDER TEST ---------------
# In the spirit of the planted-defect drift guard above, and for the same reason:
# this script's whole value is that a green brief out of the sandbox says
# something true about $SRC. When it planted `main` instead of the branch it said
# something true about code nobody was reviewing, and said it confidently. Every
# check below is a FAILURE TO PLANT, not a failure of the code under test, so it
# is loud and fatal rather than a warning someone scrolls past.
guard_fail=0
# The check RUNS INSIDE guard rather than before it: `set -e` is on, and a bare
# failing `grep -q` / `[ ]` would kill the script before it could say which marker
# was missing — a silent exit 1 from a guard is barely better than no guard.
guard() { # guard <what was expected> <test command...>
  local msg="$1"; shift
  if ! "$@"; then
    echo "plant.sh GUARD FAILED: $msg" >&2
    guard_fail=1
  fi
}
# 1. The baseline commit's PARENT must be $SRC's HEAD. This is the wording-proof
#    version of "did the code under test land" — it does not care what the branch
#    is called or which files changed on it.
parent="$(git -C "$CLONE" rev-parse HEAD~1 2>/dev/null || echo none)"
guard "the sandbox baseline sits on $parent, not on \$SRC's HEAD $SRC_SHA ($SRC_BRANCH) — the clone did NOT get the code under test" \
  test "$parent" = "$SRC_SHA"
# 2 & 3. Two distinctive markers of the S197 branch, named rather than inferred,
#    so a half-planted sandbox (e.g. dirty files copied over an old `main`, which
#    is precisely what used to happen) cannot pass on one of them alone.
guard "$CLONE/install.sh has no LCARS_INSTALL_PREFIX — this is pre-S197 install.sh" \
  grep -q 'LCARS_INSTALL_PREFIX' "$CLONE/install.sh"
guard "$CLONE/skills/lcars-buddy/ORCHESTRATION.md is missing — the shared orchestration rules did not come along" \
  test -f "$CLONE/skills/lcars-buddy/ORCHESTRATION.md"
if [ "$guard_fail" -ne 0 ]; then
  {
    echo
    echo "plant.sh: REFUSING to hand back a sandbox that does not carry the code"
    echo "under test. A brief out of it would be a FALSE GREEN — see"
    echo "ORCHESTRATION.md § Time-box and verify claims."
  } >&2
  exit 1
fi

# --- the throwaway install: ALL FIVE destinations ---------------------------
# The fifth, LCARS_VERSION_STAMP, is not written by install.sh — skills/
# lcars-version/check.sh writes it — but it defaults into $HOME like the rest, and
# an absent stamp means the version check fetches on EVERY call, which against a
# network origin blocks on a credential prompt (measured: 600 s, a hung run).
( cd "$CLONE" && \
  LCARS_SKILLS_DEST="$SKILLS" \
  LCARS_BIN_DEST="$SANDBOX/s197-bin" \
  LCARS_COPILOT_PLUGINS_DIR="$SANDBOX/s197-copilot-plugins" \
  LCARS_COPILOT_CONFIG="$SANDBOX/s197-copilot-config.json" \
  LCARS_VERSION_STAMP="$SANDBOX/s197-version-check" \
  ./install.sh >"$SANDBOX/install.log" 2>&1 )

# 4. The install must have pointed at THIS clone. A stale dest left over from an
#    earlier run would otherwise send the driver at another checkout entirely —
#    the very thing `lcars buddy`'s INSTALL SYNC section exists to catch.
buddy_target="$(readlink "$SKILLS/lcars-buddy" 2>/dev/null || echo none)"
case "$buddy_target" in
  "$CLONE"/*) ;;
  *) echo "plant.sh GUARD FAILED: $SKILLS/lcars-buddy -> $buddy_target, not into $CLONE — the install did not land on the sandbox clone" >&2
     exit 1 ;;
esac

# --- the foreign fixture repo + the planted mission -------------------------
rm -rf "$FIXTURE"; mkdir -p "$FIXTURE"; cd "$FIXTURE"
git init -q -b main
printf '# S197 fixture repo\n' > README.md
printf '# Context\n\nFixture domain glossary.\n' > CONTEXT.md
git -c user.name="S197 Rig" -c user.email="rig@example.invalid" add -A
git -c user.name="S197 Rig" -c user.email="rig@example.invalid" commit -q -m "fixture seed"
LCARS_GH_BIN="$SANDBOX/stub/gh" bash "$SKILLS/lcars-init/init.sh" >/dev/null

MID=lcars-20260911-001-s197f
D="$FIXTURE/.git/lcars/missions/$MID"
mkdir -p "$D"
cat > "$D/state.json" <<EOF
{ "id": "$MID",
  "title": "Status table drops the # on the issue number",
  "stage": "implement", "created": "2026-09-11T21:00:00Z",
  "githubIssue": 42, "workerBin": "claude",
  "paused": false, "awaitingHuman": false }
EOF
cat > "$D/events.jsonl" <<EOF
{"ts":1789181200,"mission":"$MID","stage":"implement","type":"stage_entered","detail":"implement"}
{"ts":1789181800,"mission":"$MID","stage":"implement","type":"ticket_done","detail":"T-1 render the ISSUE column"}
{"ts":1789182400,"mission":"$MID","stage":"implement","type":"breadcrumb","detail":"lcars status ISSUE column prints the bare issue number (42) instead of #42 — looks like a one-line regression in skills/lcars-status/status.sh"}
EOF

cat <<EOF

S197 rig planted.
  code under test:         $SRC @ $SRC_SHA ($SRC_BRANCH)   [guard: PASSED]
  clone (clean, on main):  $CLONE
  installed skills:        $SKILLS
  fixture repo:            $FIXTURE
  refusing shims (PATH):   $SHIM   (expected worker invocations: 0)

Drive it from the fixture repo with \$SHIM first on PATH:
  cd $FIXTURE
  PATH="$SHIM:\$PATH" LCARS_SKILLS_DEST=$SKILLS bash $SKILLS/lcars-buddy/buddy.sh

To exercise the pre-flight refusal, dirty the clone first:
  echo x >> $CLONE/vision.md
EOF
