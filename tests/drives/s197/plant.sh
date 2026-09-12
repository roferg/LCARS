#!/usr/bin/env bash
#
# tests/drives/s197/plant.sh — rebuild the S197 buddy-orchestrator proof rig.
#
# Builds the sandbox the S197 tester drove: a throwaway LCARS clone carrying the
# WIP buddy on a CLEAN `main` (buddy's pre-flight refuses a dirty tree or a
# non-main branch), a throwaway install with ALL FOUR install destinations
# redirected, a foreign fixture repo with one planted mission whose events.jsonl
# ends in a breadcrumb, and the one-line defect that breadcrumb describes.
#
# WHY ALL FOUR DESTINATIONS: install.sh has four, and three default into $HOME
# (LCARS_BIN_DEST -> ~/.local/bin, LCARS_COPILOT_PLUGINS_DIR -> ~/.copilot/...,
# LCARS_COPILOT_CONFIG -> ~/.copilot/config.json). Setting only
# LCARS_SKILLS_DEST repoints the captain's REAL launchers and Copilot plugin at
# the throwaway clone. This happened on 2026-09-11 and had to be repaired.
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

# --- the clone: WIP content, on a CLEAN `main` ------------------------------
# A plain `git clone` of a worktree carries only COMMITTED content, so an
# uncommitted WIP buddy would not come along. Copy the dirty files over, then
# commit them onto the clone's own main so the tree is clean — buddy refuses to
# stack a fix onto a dirty or non-main checkout, and that refusal is under test.
rm -rf "$CLONE"
git clone -q "$SRC" "$CLONE"
git -C "$CLONE" checkout -q main 2>/dev/null || git -C "$CLONE" checkout -q -b main origin/main
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
  commit -q -m "sandbox baseline: WIP buddy + one planted defect in lcars-status"

# --- the throwaway install: ALL FOUR destinations ---------------------------
( cd "$CLONE" && \
  LCARS_SKILLS_DEST="$SKILLS" \
  LCARS_BIN_DEST="$SANDBOX/s197-bin" \
  LCARS_COPILOT_PLUGINS_DIR="$SANDBOX/s197-copilot-plugins" \
  LCARS_COPILOT_CONFIG="$SANDBOX/s197-copilot-config.json" \
  ./install.sh >"$SANDBOX/install.log" 2>&1 )

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
