#!/usr/bin/env bash
#
# Tests for THE WORKER FENCE (S168).
#
# Sources under test:
#   skills/lcars-run/worker-adapter.sh  adapter_deny + the claude --disallowedTools
#                                       emission + the spawn-time refusal.
#   skills/lcars-run/run.sh             worker_input_dirs (the narrowed grant) and
#                                       the post-turn fence audit in worker_spawn.
#   skills/lcars-launch/launch.sh       the launch role's Write-and-no-shell
#                                       posture + its checkout-clean audit.
#
# WHY THIS EXISTS. Three separate things were documented as fences and were not:
#
#   1. claude's `--allowedTools` is a PRE-APPROVAL list, not a restriction, and
#      `--dangerously-skip-permissions` waives whatever is left to ask about
#      (MEASURED, S124: `--allowedTools Read,Grep,Glob --dangerously-skip-
#      permissions` still CREATED A FILE). `--disallowedTools` is the flag that
#      actually refuses, and its refusal survives delegation to a subagent.
#   2. every cold worker was granted `--add-dir` on the WHOLE `.git/lcars` store
#      — every mission's state, including the state that JUDGES it — and on
#      copilot `--add-dir` grants WRITE, not read.
#   3. the `launch` inspector held a SHELL and no Write, so it authored its
#      discovery JSON through bash inside a checkout of the captain's code while
#      its prompt said "inspection only".
#
# HOW THIS SUITE JUDGES. Only positive assertions: a flag is PRESENT and carries
# an EXACT value; an argv is BYTE-IDENTICAL to a fixture captured from `main`; a
# breach EVENT is emitted and the stage exits NON-ZERO. It never asserts the mere
# ABSENCE of a tool name — an absence proved nothing here for a year (that is
# precisely what defect 1 above is), and the holodeck suite learned the same
# lesson at S124. Real filesystem, real git, recording stubs via
# $LCARS_WORKER_BIN / $LCARS_WORKER_ADAPTER. NO model is ever called.
#
# Usage: bash tests/worker-fence.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="${LCARS_WORKER_ADAPTER:-$REPO_ROOT/skills/lcars-run/worker-adapter.sh}"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
LAUNCH_SH="$REPO_ROOT/skills/lcars-launch/launch.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
TMPROOT_P="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

export LCARS_VERSION_CHECK=0
export LCARS_WORKER_HANG_SECS=0

# --- THE MONEY GUARD -------------------------------------------------------
# Shadow both real CLIs with executables that refuse loudly and record the
# attempt, FIRST on $PATH for the whole suite. Nothing here can spend.
SHIMDIR="$TMPROOT/shims"; mkdir -p "$SHIMDIR"
SPEND_LOG="$TMPROOT/spend.log"; : >"$SPEND_LOG"
for cli in claude copilot; do
  cat >"$SHIMDIR/$cli" <<EOF
#!/usr/bin/env bash
echo "REAL-CLI-SPAWN-ATTEMPT $cli \$*" >>"$SPEND_LOG"
exit 97
EOF
  chmod +x "$SHIMDIR/$cli"
done
export PATH="$SHIMDIR:$PATH"
no_spend() { [ ! -s "$SPEND_LOG" ]; }

MID="lcars-20260830-001"
SIB="lcars-20260830-002"
BUG="lcars-20260830-003"

# ============================================================================
# 1. THE DENY LIST — the flag is PRESENT and its VALUE is exact, per role
# ============================================================================
printf '\n  -- 1. every claude role argv carries an exact --disallowedTools --\n'

d1="$(mktemp -d "$TMPROOT/d.XXXX")"
# The value that FOLLOWS the --disallowedTools token in the argv (not the table).
deny_in_argv() { # role → the emitted deny list
  LCARS_WORKER_MODEL= LCARS_WORKER_INPUT_DIRS= \
    bash "$ADAPTER" argv claude "$1" "$d1" | awk '/^--disallowedTools$/{getline; print}'
}
# NB: `cmd | grep -q` is UNSAFE in this suite — `set -o pipefail` turns grep's
# early exit into a SIGPIPE (141) for the producer and the whole pipeline reads
# as a failure. Every grep here therefore runs over a captured file or inside a
# command substitution whose status is discarded.
argv_of() { # cli role [env-prefix…] → the argv, one flag per line, in a file
  LCARS_WORKER_MODEL="${MDL:-}" LCARS_WORKER_INPUT_DIRS="${IDS:-}" \
    bash "$ADAPTER" argv "$1" "$2" "$d1" >"$TMPROOT/argv.now" 2>/dev/null
  printf '%s\n' "$TMPROOT/argv.now"
}
has_flag() { # role → 0 when the flag token itself is present
  argv_of claude "$1" >/dev/null
  grep -qxF -- '--disallowedTools' "$TMPROOT/argv.now"
}

for r in repo-read repo-read-web repo-write launch default; do
  check "1a. claude $r argv carries the --disallowedTools FLAG" "has_flag $r"
done

check "1b. repo-read denies Edit,Bash,NotebookEdit,WebSearch,WebFetch (KEEPS Write — the answer artifact is its whole output)" \
  "[ \"\$(deny_in_argv repo-read)\" = 'Edit,Bash,NotebookEdit,WebSearch,WebFetch' ]"
check "1c. repo-read-web denies Edit,Bash,NotebookEdit (it is a research role — the network stays)" \
  "[ \"\$(deny_in_argv repo-read-web)\" = 'Edit,Bash,NotebookEdit' ]"
# The honesty note, asserted rather than merely commented: repo-write HOLDS Bash,
# so this row is NOT a fence and must not pretend to be one. Its containment is
# the isolated worktree + declared edits + the post-commit scope check + flip-flop.
check "1d. repo-write denies NotebookEdit ONLY — it holds a shell, so no tool list can fence it" \
  "[ \"\$(deny_in_argv repo-write)\" = 'NotebookEdit' ]"
check "1d2. …and repo-write's GRANT still names Bash, so the deny list claims no fence it does not have" \
  "argv_of claude repo-write >/dev/null; grep -qxF 'Read,Grep,Glob,Write,Edit,Bash' \"\$TMPROOT/argv.now\""
check "1e. launch denies Edit,Bash,NotebookEdit" \
  "[ \"\$(deny_in_argv launch)\" = 'Edit,Bash,NotebookEdit' ]"
check "1e2. …and launch's GRANT is Read,Grep,Glob,Write — the shell swapped for a pen" \
  "argv_of claude launch >/dev/null; grep -qxF 'Read,Grep,Glob,Write' \"\$TMPROOT/argv.now\""
check "1f. default denies Write,Edit,Bash,NotebookEdit,WebSearch,WebFetch" \
  "[ \"\$(deny_in_argv default)\" = 'Write,Edit,Bash,NotebookEdit,WebSearch,WebFetch' ]"

# The flag must survive the OTHER argv variations, not just the bare call.
check "1g. the deny flag survives --model being set" \
  "MDL=some-model argv_of claude repo-read >/dev/null; grep -qxF -- '--disallowedTools' \"\$TMPROOT/argv.now\""
check "1h. the deny flag survives input dirs being supplied" \
  "IDS=\"\$d1\" argv_of claude repo-write >/dev/null; grep -qxF -- '--disallowedTools' \"\$TMPROOT/argv.now\""

# --- the spawn-time refusal (promoted from the holodeck's _assert_no_bash) ----
# Keyed off the ENGINE, never off the presence of --allowedTools: keyed off that
# flag, a later session dropping it for an unrelated reason would retire the
# requirement silently. Proven by MUTATING a copy of the adapter so its claude
# argv carries no deny list, then asserting the spawn REFUSES.
UNFENCED="$TMPROOT/unfenced-adapter.sh"
sed "s/'--allowedTools' \"\$tools\" '--disallowedTools' \"\$deny\" \\\\/'--allowedTools' \"\$tools\" \\\\/" \
  "$ADAPTER" >"$UNFENCED"
dS="$(mktemp -d "$TMPROOT/d.XXXX")"; mkdir -p "$dS/bin"
cat >"$dS/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'RAN\n' >>"$dS/ran.log"
exit 0
EOF
chmod +x "$dS/bin/claude"
LCARS_WORKER_MODEL= LCARS_WORKER_INPUT_DIRS= bash "$UNFENCED" argv claude repo-read "$dS" >"$TMPROOT/unfenced.argv" 2>/dev/null
check "1i. (setup) the mutated adapter really does emit an argv with NO deny list" \
  "[ -s \"\$TMPROOT/unfenced.argv\" ] && ! grep -qxF -- '--disallowedTools' \"\$TMPROOT/unfenced.argv\""
LCARS_WORKER_BIN="$dS/bin/claude" bash "$UNFENCED" spawn claude repo-read "$dS/out" "p" >/dev/null 2>&1
rc_unfenced=$?
check "1j. a claude spawn whose argv lacks --disallowedTools FAILS THE SPAWN" \
  "[ \"\$rc_unfenced\" != '0' ]"
check "1k. …and the CLI was never run (refused before spend, not after)" \
  "[ ! -f \"\$dS/ran.log\" ]"
# copilot is exempt for a REASON: --available-tools IS a restriction there and the
# CLI has no --disallowedTools to carry. So the same mutated adapter must still
# spawn copilot happily.
mkdir -p "$dS/cbin"
cat >"$dS/cbin/copilot" <<EOF
#!/usr/bin/env bash
printf 'RAN\n' >>"$dS/cran.log"
exit 0
EOF
chmod +x "$dS/cbin/copilot"
LCARS_WORKER_BIN="$dS/cbin/copilot" bash "$ADAPTER" spawn copilot repo-read "$dS/cout" "p" >/dev/null 2>&1
check "1l. copilot is EXEMPT from the deny-flag requirement and still spawns" \
  "[ -f \"\$dS/cran.log\" ]"

# ============================================================================
# 2. COPILOT'S ARGV IS BYTE-IDENTICAL TO PRE-168
# ============================================================================
# Not a hand-typed expectation: the fixture is generated by running the adapter
# AS IT STOOD ON MAIN over the full matrix (5 roles x model-on/off x three
# input-dir shapes) and diffing. The `launch` TOOL LIST is the ONE intended
# change and is pinned separately below.
printf '\n  -- 2. copilot argv byte-identical to pre-168 (real fixture, not a guess) --\n'

PRE168="$TMPROOT/pre168-adapter.sh"
( cd "$REPO_ROOT" && git show main:skills/lcars-run/worker-adapter.sh ) >"$PRE168" 2>/dev/null
check "2a. (setup) the pre-168 adapter was recovered from main" "[ -s \"\$PRE168\" ]"

mkdir -p "$TMPROOT/mx/o" "$TMPROOT/mx/i1" "$TMPROOT/mx/i2"
copilot_matrix() { # adapter-path [roles…]
  local a="$1"; shift
  local r m dirs
  for r in "$@"; do
    for m in "" some-model; do
      for dirs in "" "$TMPROOT/mx/i1" "$TMPROOT/mx/i1
$TMPROOT/mx/i2"; do
        printf '### role=%s model=%s\n' "$r" "$m"
        LCARS_WORKER_MODEL="$m" LCARS_WORKER_INPUT_DIRS="$dirs" \
          bash "$a" argv copilot "$r" "$TMPROOT/mx/o"
      done
    done
  done
}
copilot_matrix "$PRE168"  repo-read repo-read-web repo-write default >"$TMPROOT/mx/pre.txt"
copilot_matrix "$ADAPTER" repo-read repo-read-web repo-write default >"$TMPROOT/mx/post.txt"
check "2b. copilot argv for repo-read/-web/-write/default is BYTE-IDENTICAL across the whole input-dirs matrix" \
  "diff -q \"\$TMPROOT/mx/pre.txt\" \"\$TMPROOT/mx/post.txt\" >/dev/null"
check "2c. (guard) the matrix fixture is not empty" \
  "[ \"\$(wc -l <\"\$TMPROOT/mx/pre.txt\" | tr -d ' ')\" -gt 100 ]"
# The ONE intended copilot change: the launch role trades its shell for `create`,
# because the two engines' postures are meant to mirror.
copilot_matrix "$PRE168"  launch >"$TMPROOT/mx/pre-launch.txt"
copilot_matrix "$ADAPTER" launch >"$TMPROOT/mx/post-launch.txt"
check "2d. copilot launch is the ONE intended change: every differing line is the tool list" \
  "[ -z \"\$(diff \"\$TMPROOT/mx/pre-launch.txt\" \"\$TMPROOT/mx/post-launch.txt\" | grep -E '^[<>]' | grep -vE 'view,grep,glob,(bash|create)')\" ]"
check "2e. …and the new copilot launch list is exactly view,grep,glob,create" \
  "[ \"\$(bash \"\$ADAPTER\" argv copilot launch \"\$TMPROOT/mx/o\" 2>/dev/null | sed -n '4p')\" = 'view,grep,glob,create' ]"
bash "$ADAPTER" argv copilot repo-read "$TMPROOT/mx/o" >"$TMPROOT/cop.argv" 2>/dev/null
check "2f. copilot argv still carries NO --disallowedTools (the CLI has no such flag)" \
  "[ -s \"\$TMPROOT/cop.argv\" ] && ! grep -qxF -- '--disallowedTools' \"\$TMPROOT/cop.argv\""

# ============================================================================
# 3. AN UNKNOWN ROLE IS NON-ZERO FROM BOTH TABLES; NO SILENT EMPTY DENY LIST
# ============================================================================
# This is the test that stops the NEXT role shipping unfenced.
printf '\n  -- 3. both tables refuse an unknown role; a tools-without-deny role is a HARD ERROR --\n'

for cli in claude copilot; do
  bash "$ADAPTER" argv "$cli" nonesuch "$d1" >/dev/null 2>"$TMPROOT/e.$cli"; rc_a=$?
  check "3a. $cli: the TOOLS table refuses an unknown role (non-zero)" "[ \"\$rc_a\" != '0' ]"
  check "3a2. $cli: …with a message on stderr, never a silent empty argv" "[ -s \"\$TMPROOT/e.\$cli\" ]"
  bash "$ADAPTER" deny "$cli" nonesuch >/dev/null 2>"$TMPROOT/ed.$cli"; rc_d=$?
  check "3b. $cli: the DENY table refuses an unknown role (non-zero)" "[ \"\$rc_d\" != '0' ]"
  check "3b2. $cli: …with a message on stderr" "[ -s \"\$TMPROOT/ed.\$cli\" ]"
done
check "3c. an unknown CLI is non-zero from the deny table too" \
  "! bash \"\$ADAPTER\" deny nosuchcli repo-read >/dev/null 2>&1"

# A role that HAS tools but NO deny entry must be a hard error — not an empty
# `--disallowedTools`, which would ship the role unfenced while looking fenced.
HOLED="$TMPROOT/holed-adapter.sh"
# `newrole` is a role that HAS a tool list in BOTH engine tables and a deny entry
# in NEITHER — the exact shape of "a new role shipped without anyone thinking
# about its fence". Built by RENAMING the tools table's `default` row in each
# engine column (the deny table's own `default` row is worded differently and is
# left untouched), so the hole is real rather than described.
sed -e "s|^        default)       printf 'Read' ;;|        newrole)       printf 'Read' ;;|" \
    -e "s|^        default)       printf 'view' ;;|        newrole)       printf 'view' ;;|" \
    "$ADAPTER" >"$HOLED"
check "3d. (setup) the holed adapter gives newrole a TOOL row in BOTH engine columns" \
  "[ \"\$(grep -c '^        newrole)' \"\$HOLED\")\" = '2' ]"
check "3d2. (setup) …and NO deny entry for it, on either engine" \
  "! bash \"\$HOLED\" deny claude newrole >/dev/null 2>&1 && ! bash \"\$HOLED\" deny copilot newrole >/dev/null 2>&1"
bash "$HOLED" argv claude newrole "$d1" >"$TMPROOT/holed.out" 2>"$TMPROOT/holed.err"; rc_holed=$?
check "3e. a role with TOOLS but no DENY entry is a HARD ERROR (non-zero)" \
  "[ \"\$rc_holed\" != '0' ]"
check "3f. …and it emitted no argv at all — never a silent empty deny list" \
  "! grep -qxF -- '--disallowedTools' \"\$TMPROOT/holed.out\""

# ============================================================================
# 4. THE GRANT — a worker on mission A reaches no path into mission B
# ============================================================================
printf '\n  -- 4. the path grant is narrowed to THIS mission (front-half / Implement / reconcile) --\n'

# A recording worker-adapter: reports the grant it was handed, then writes the
# canned artifact each front-half role needs so the Stage completes.
make_rec_adapter() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"
[ "$sub" = "spawn" ] || exit 0
{
  printf 'role=%s\n' "$role"
  printf 'input_dirs=%s\n' "$(printf '%s' "${LCARS_WORKER_INPUT_DIRS:-}" | tr '\n' '|')"
} >>"$RECORD"
mkdir -p "$outdir"
case "$role" in
  research-questions) : >"$outdir/questions.txt" ;;
  research-grounding)
    cat >"$outdir/grounding.json" <<'JSON'
{ "targets": ["src/base.txt"], "kind": "modify-existing",
  "restated": "the control is wired to the wrong handler",
  "reuse_directive": "Modify the delivered code; do NOT add a parallel control." }
JSON
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

new_repo() { # → repo dir, with missions MID + SIB seeded
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  (
    cd "$repo"
    git init -q -b main
    git config user.email t@t; git config user.name t
    mkdir -p src; printf 'base\n' >src/base.txt
    printf '# Context\n\nA fixture repo.\n' >CONTEXT.md
    git add -A && git commit -q -m init
    git checkout -q -b "lcars/$MID"; printf 'm\n' >src/m.txt; git add -A; git commit -q -m mission
    git checkout -q main
    git checkout -q -b "lcars/$SIB"; printf 's\n' >src/s.txt; git add -A; git commit -q -m sibling
    git checkout -q main
    git checkout -q -b "lcars/$BUG"; git commit -q --allow-empty -m bug
    git checkout -q main
  ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  printf '{ "projectName": "fixture" }\n' >"$repo/.git/lcars/config.json"
  make_rec_adapter "$repo.adapter"
  printf '#!/usr/bin/env bash\nexit 96\n' >"$repo.worker"; chmod +x "$repo.worker"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo.gh"; chmod +x "$repo.gh"
  printf '%s\n' "$repo"
}

seed_mission() { # repo id [extra-state]
  local repo="$1" id="$2" extra="${3:-}"
  local d="$repo/.git/lcars/missions/$id"; mkdir -p "$d"
  cat >"$d/state.json" <<JSON
{ "id": "$id", "type": "feature", "title": "t", "stage": "align",
  "branch": "lcars/$id", "base": "main", "githubIssue": null$extra }
JSON
  printf '# Mission\n\n**Goal:** something.\n' >"$d/prd.md"
  printf '%s\n' "$d"
}

stage() { # repo id action [env…]
  local repo="$1" id="$2" action="$3"; shift 3
  : >"$repo.record"
  OUT="$( cd "$repo" && env LCARS_GH_BIN="$repo.gh" LCARS_WORKER_BIN="$repo.worker" \
      LCARS_WORKER_ADAPTER="$repo.adapter" LCARS_WORKER_CLI=claude \
      RECORD="$repo.record" "$@" bash "$SCRIPT" "$action" --mission "$id" 2>&1 )"
  RC=$?
}
rec() { sed -n "s/^$2=//p" "$1.record" 2>/dev/null | head -1; }

r4="$(new_repo)"
seed_mission "$r4" "$MID" >/dev/null
seed_mission "$r4" "$SIB" >/dev/null
stage "$r4" "$MID" research
G4="$(rec "$r4" input_dirs)"
check "4a. front-half: the grant names THIS mission's dir" \
  "[ -n \"\$(printf '%s' \"\$G4\" | grep -F \"missions/$MID\")\" ]"
check "4b. front-half: the grant reaches NO path into the sibling mission" \
  "[ -z \"\$(printf '%s' \"\$G4\" | grep -F \"$SIB\")\" ]"
check "4c. front-half: the grant is NOT the whole .git/lcars store" \
  "[ \"\$G4\" != \"$r4/.git/lcars\" ] && [ -z \"\$(printf '%s' \"\$G4\" | tr '|' '\\n' | grep -xF \"$r4/.git/lcars\")\" ]"
check "4d. front-half: config.json's dir is NOT granted (nothing reads it from a prompt)" \
  "[ -z \"\$(printf '%s' \"\$G4\" | tr '|' '\\n' | grep -xF \"$r4/.git/lcars\")\" ]"
check "4e. no real CLI was ever spawned" 'no_spend'

# A Mission-Log bug CHILD is the ONE documented cross-mission read: its grounding
# worker is handed $parent/prd.md, validated-plan.md and plan.json BY PATH. That
# grant must appear for a child and ONLY for a child.
r4b="$(new_repo)"
seed_mission "$r4b" "$MID" >/dev/null
seed_mission "$r4b" "$SIB" >/dev/null
seed_mission "$r4b" "$BUG" ',
  "origin": "log", "parentMission": "'"$MID"'", "parentIssue": 42' >/dev/null
stage "$r4b" "$BUG" research
G4B="$(rec "$r4b" input_dirs)"
check "4f. a bug child's grant names its OWN dir" \
  "[ -n \"\$(printf '%s' \"\$G4B\" | grep -F \"missions/$BUG\")\" ]"
check "4g. …and its PARENT's dir, which grounding reads by path" \
  "[ -n \"\$(printf '%s' \"\$G4B\" | grep -F \"missions/$MID\")\" ]"
check "4h. …and STILL reaches no unrelated sibling mission" \
  "[ -z \"\$(printf '%s' \"\$G4B\" | grep -F \"$SIB\")\" ]"

# THE CONTEXT PACK IS GRANTED AS A DIRECTORY OF ITS OWN (S213).
#
# It used to be granted as the FILE, on the strength of a measurement against
# copilot 1.0.60. copilot 1.0.86 refuses a file to `--add-dir` at ARGV-PARSE
# ("Not a directory"), so every copilot worker died the instant a pack existed —
# before the model ran, writing nothing, and reported downstream as "produced no
# questions.txt". Granting the file's old directory is not the cure either: that
# directory is the store root, holding every OTHER mission's state, which is the
# exact widening this whole section narrowed away. So the pack now LIVES in a
# directory of its own and the grant names that directory: one dir, one file,
# no other mission inside it. A repo with a root CONTEXT.md needs no grant at all.
r4c="$(new_repo)"
rm -f "$r4c/CONTEXT.md"
( cd "$r4c" && git add -A && git commit -q -m "drop CONTEXT.md" ) >/dev/null 2>&1
mkdir -p "$r4c/.git/lcars/context"
printf '# pack\n' >"$r4c/.git/lcars/context/context-pack.md"
seed_mission "$r4c" "$MID" >/dev/null
seed_mission "$r4c" "$SIB" >/dev/null
stage "$r4c" "$MID" research
G4C="$(rec "$r4c" input_dirs)"
check "4l. EVERY path in the grant is a DIRECTORY — copilot's --add-dir takes nothing else" \
  "printf '%s' \"\$G4C\" | tr '|' '\\n' | while IFS= read -r p; do [ -z \"\$p\" ] || [ -d \"\$p\" ] || exit 1; done"
check "4m. …and the grant is still NOT the store root" \
  "[ -z \"\$(printf '%s' \"\$G4C\" | tr '|' '\\n' | grep -xF \"$r4c/.git/lcars\")\" ]"
check "4n. …and the pack the worker is told to read sits INSIDE a granted dir" \
  "[ -n \"\$(printf '%s' \"\$G4C\" | tr '|' '\\n' | grep -xF \"$r4c/.git/lcars/context\")\" ] && [ -f \"$r4c/.git/lcars/context/context-pack.md\" ]"
check "4o. …and it still reaches no sibling mission" \
  "[ -z \"\$(printf '%s' \"\$G4C\" | grep -F \"$SIB\")\" ]"

# A repo whose pack was written at the LEGACY store-root path keeps working: the
# pack is relocated into its own directory once, and the grant that results is a
# directory like any other. Without this, every repo the captain already has
# would go on handing copilot a file.
r4d="$(new_repo)"
rm -f "$r4d/CONTEXT.md"
( cd "$r4d" && git add -A && git commit -q -m "drop CONTEXT.md" ) >/dev/null 2>&1
printf '# legacy pack\n' >"$r4d/.git/lcars/context-pack.md"
seed_mission "$r4d" "$MID" >/dev/null
stage "$r4d" "$MID" research
G4D="$(rec "$r4d" input_dirs)"
check "4p. a legacy store-root pack is relocated into the pack's own directory" \
  "[ -f \"$r4d/.git/lcars/context/context-pack.md\" ] && grep -q 'legacy pack' \"$r4d/.git/lcars/context/context-pack.md\""
check "4q. …the old store-root file is gone, so nothing can grant it again" \
  "[ ! -f \"$r4d/.git/lcars/context-pack.md\" ]"
check "4r. …and every path in THAT grant is a directory too" \
  "printf '%s' \"\$G4D\" | tr '|' '\\n' | while IFS= read -r p; do [ -z \"\$p\" ] || [ -d \"\$p\" ] || exit 1; done"

# The other two grant sites. The Implement site hands the SAME traced helper the
# front-half assertions above prove; reconcile was already narrow (worktree +
# this mission's dir) and is left as it stood.
check "4i. the Implement site grants worker_input_dirs, not the store root" \
  "grep -q 'export LCARS_WORKER_INPUT_DIRS=\"\$(worker_input_dirs)\"' \"\$SCRIPT\" && [ \"\$(grep -c 'export LCARS_WORKER_INPUT_DIRS=\"\$(worker_input_dirs)\"' \"\$SCRIPT\")\" = '2' ]"
check "4j. NO grant site hands out \$(dirname \"\$LCARS_CFG\") any more" \
  "! grep -q 'LCARS_WORKER_INPUT_DIRS=\"\$(dirname \"\$LCARS_CFG\")\"' \"\$SCRIPT\""
check "4k. the reconcile site grants only the merge worktree + THIS mission's dir" \
  "grep -q 'LCARS_WORKER_INPUT_DIRS=\"\$wt' \"\$SCRIPT\" && grep -q '^\$MISSION_DIR\" *\\\\\$' \"\$SCRIPT\""

# ============================================================================
# 5. THE POST-TURN AUDIT — the only fence that works on BOTH engines
# ============================================================================
printf '\n  -- 5. the post-turn audit: breach is loud, an honest run is a no-op --\n'

# `run.sh spawn-stage <role>` drives the REAL worker_spawn chokepoint with the
# REAL adapter and a stub binary, so this exercises the shipped path.
mk_repo5() { # → repo with one mission
  local repo; repo="$(mktemp -d "$TMPROOT/r5.XXXX")"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t \
      && printf 'x\n' >f.txt && git add -A && git commit -q -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/$MID"
  printf '{ "projectName": "fixture" }\n' >"$repo/.git/lcars/config.json"
  cat >"$repo/.git/lcars/missions/$MID/state.json" <<JSON
{ "id": "$MID", "stage": "research", "branch": "lcars/$MID", "base": "main" }
JSON
  printf '{"ts":1,"mission":"%s","stage":"research","type":"seed","detail":"x"}\n' "$MID" \
    >"$repo/.git/lcars/missions/$MID/events.jsonl"
  printf '[]\n' >"$repo/.git/lcars/missions/$MID/plan.json"
  printf '%s\n' "$repo"
}
# A stub CLI named `claude` (the basename picks the adapter column). $MUTATE, when
# set, is a file the stub scribbles on — standing in for a read-role worker that
# writes where it must not.
mk_stub5() { # dir
  mkdir -p "$1"
  cat >"$1/claude" <<'EOF'
#!/usr/bin/env bash
[ -n "${MUTATE:-}" ] && printf 'TAMPERED\n' >>"$MUTATE"
exit 0
EOF
  chmod +x "$1/claude"
}
# Usage capture is OFF here: it is best-effort telemetry that appends its own
# `worker_usage` event AFTER the audit window closes, and it would mask the very
# thing 5a-5e are measuring — whether THE AUDIT writes anything on an honest run.
spawn5() { # repo [env…]
  local repo="$1"; shift
  OUT5="$( cd "$repo" && env LCARS_WORKER_BIN="$TMPROOT/stub5/claude" \
      LCARS_USAGE_CAPTURE=0 LCARS_NOW=1700000000 "$@" \
      bash "$SCRIPT" spawn-stage --mission "$MID" research 2>&1 )"
  RC5=$?
}
mk_stub5 "$TMPROOT/stub5"

# --- 5a. an HONEST turn writes not one byte and emits not one event -----------
rH="$(mk_repo5)"
EH="$rH/.git/lcars/missions/$MID/events.jsonl"
cp "$EH" "$TMPROOT/events.before"
before_state="$(cat "$rH/.git/lcars/missions/$MID/state.json")"
spawn5 "$rH"
check "5a. an honest read-role turn exits ZERO" "[ \"\$RC5\" = '0' ]"
check "5b. …and the event stream is BYTE-IDENTICAL to before the turn (the audit writes nothing)" \
  "cmp -s \"\$TMPROOT/events.before\" \"\$EH\""
check "5c. …and state.json is untouched" \
  "[ \"\$(cat \"\$rH/.git/lcars/missions/$MID/state.json\")\" = \"\$before_state\" ]"
check "5d. …and no worker_fence_breach event was emitted" \
  "! grep -q worker_fence_breach \"\$EH\""
# The same turn with the audit DISABLED must produce the identical stream — the
# audit itself adds nothing on an honest run.
rH2="$(mk_repo5)"
spawn5 "$rH2" LCARS_WORKER_FENCE=0
check "5e. the audit adds NOTHING: fence-on and fence-off event streams are byte-identical" \
  "cmp -s \"\$EH\" \"\$rH2/.git/lcars/missions/$MID/events.jsonl\""

# --- 5f. a read-role worker that mutates state.json is a BREACH ---------------
rB="$(mk_repo5)"
EB="$rB/.git/lcars/missions/$MID/events.jsonl"
spawn5 "$rB" MUTATE="$rB/.git/lcars/missions/$MID/state.json"
check "5f. a repo-read worker that writes state.json FAILS THE STAGE (non-zero)" \
  "[ \"\$RC5\" != '0' ]"
check "5g. …and a worker_fence_breach event is emitted" \
  "grep -q worker_fence_breach \"\$EB\""
check "5h. …naming the file it touched" \
  "[ -n \"\$(grep worker_fence_breach \"\$EB\" | grep -F 'state.json')\" ]"
check "5i. …and the message says the state was NOT repaired" \
  "[ -n \"\$(printf '%s' \"\$OUT5\" | grep -i 'nothing has been repaired')\" ]"
check "5j. …and the tampering is STILL THERE — never silently reverted" \
  "grep -q TAMPERED \"\$rB/.git/lcars/missions/$MID/state.json\""

# --- 5k. the same for the other watched artifacts, and the exempt role ---------
rB2="$(mk_repo5)"
spawn5 "$rB2" MUTATE="$rB2/.git/lcars/missions/$MID/plan.json"
check "5k. a read-role worker that writes plan.json is a breach too" "[ \"\$RC5\" != '0' ]"
rB3="$(mk_repo5)"
spawn5 "$rB3" MUTATE="$rB3/.git/lcars/missions/$MID/events.jsonl"
check "5l. a read-role worker that appends to events.jsonl is a breach" "[ \"\$RC5\" != '0' ]"
# repo-write is EXEMPT by design (it holds a shell and legitimately writes; its
# containment is the worktree + declared edits + the post-commit scope check +
# flip-flop). `spawn-stage` hard-codes the repo-read TOOLSET, so proving the
# exemption needs a copy of run.sh whose test surface passes the role through —
# the same "mutate a copy to prove the mechanism" idiom section 3 uses. The
# ADAPTER is pinned by env so the copy's relative resolution cannot drift.
RUNRW="$TMPROOT/run-rolepass.sh"
sed 's|LCARS_WORKER_ROLE="\$role" worker_spawn "repo-read" "\$outdir" "test prompt"|LCARS_WORKER_ROLE="$role" worker_spawn "$role" "$outdir" "test prompt"|' \
  "$SCRIPT" >"$RUNRW"
check "5m. (setup) the role-passing copy really does thread the role to the toolset" \
  "grep -q 'worker_spawn \"\$role\" \"\$outdir\" \"test prompt\"' \"\$RUNRW\""
rW="$(mk_repo5)"
OUT5="$( cd "$rW" && env LCARS_WORKER_BIN="$TMPROOT/stub5/claude" LCARS_NOW=1700000000 \
    LCARS_USAGE_CAPTURE=0 LCARS_WORKER_ADAPTER="$ADAPTER" \
    MUTATE="$rW/.git/lcars/missions/$MID/state.json" \
    bash "$RUNRW" spawn-stage --mission "$MID" repo-write 2>&1 )"; RC5=$?
check "5m2. a repo-write worker writing state.json is NOT a breach — it is exempt by design" \
  "[ \"\$RC5\" = '0' ]"
check "5m3. (control) the SAME stub under a repo-read toolset IS a breach" \
  "rC=\"\$(mk_repo5)\"; ( cd \"\$rC\" && env LCARS_WORKER_BIN=\"\$TMPROOT/stub5/claude\" LCARS_NOW=1700000000 LCARS_USAGE_CAPTURE=0 LCARS_WORKER_ADAPTER=\"\$ADAPTER\" MUTATE=\"\$rC/.git/lcars/missions/$MID/state.json\" bash \"\$RUNRW\" spawn-stage --mission \"$MID\" repo-read >/dev/null 2>&1 ); [ \"\$?\" != '0' ]"
check "5n. no real CLI was ever spawned" 'no_spend'

# ============================================================================
# 6. LAUNCH — discovery still works with Write-and-no-Bash; a dirty tree is a breach
# ============================================================================
printf '\n  -- 6. launch: the inspector authors its artifact and leaves the checkout alone --\n'

mk_repo6() { # id → repo
  local id="$1" root; root="$(mktemp -d "$TMPROOT/l6.XXXX")"
  (
    cd "$root"
    git init -q; git config user.email t@t; git config user.name t
    git symbolic-ref HEAD refs/heads/trunk
    printf 'root\n' >README.md; git add -A; git commit -qm init
    git checkout -qb "lcars/$id"; printf 'app\n' >app.txt; git add -A; git commit -qm work
    git checkout -q trunk
  ) >/dev/null 2>&1
  mkdir -p "$root/.git/lcars/missions/$id"
  cat >"$root/.git/lcars/missions/$id/state.json" <<JSON
{ "id": "$id", "stage": "verify", "branch": "lcars/$id", "base": "trunk" }
JSON
  printf '%s\n' "$root"
}

L6="$TMPROOT_P/lroot6"
# An HONEST inspector: it uses only its pen — writes its discovery artifact and
# touches nothing in the checkout.
mk_honest_inspector() { # dir
  mkdir -p "$1"
  cat >"$1/claude" <<'EOF'
#!/usr/bin/env bash
cat >"$LCARS_LAUNCH_JSON" <<'JSON'
{ "target": "the fixture app", "command": "perl -e 'select(undef,undef,undef,20)'",
  "cwd": ".", "url": "", "howToStop": "stop it", "status": "ready" }
JSON
exit 0
EOF
  chmod +x "$1/claude"
}
# A DIRTY inspector: it writes its artifact AND edits the checkout it was told to
# only inspect. Exactly what the old shell-holding posture made possible.
mk_dirty_inspector() { # dir wt
  mkdir -p "$1"
  cat >"$1/claude" <<EOF
#!/usr/bin/env bash
cat >"\$LCARS_LAUNCH_JSON" <<'JSON'
{ "target": "the fixture app", "command": "perl -e 'select(undef,undef,undef,20)'",
  "cwd": ".", "url": "", "howToStop": "stop it", "status": "ready" }
JSON
printf 'the inspector edited this\n' >>"$2/app.txt"
exit 0
EOF
  chmod +x "$1/claude"
}

R6="$(mk_repo6 m6)"
mk_honest_inspector "$TMPROOT/ins6"
OUT6="$( cd "$R6" && LCARS_LAUNCH_ROOT="$L6" LCARS_WORKER_BIN="$TMPROOT/ins6/claude" \
    LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m6 2>&1 )"; RC6=$?
LJ6="$R6/.git/lcars/missions/m6/launch.json"
P6="$(sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' "$LJ6" 2>/dev/null | head -1)"
check "6a. discovery still SUCCEEDS with Write-and-no-Bash (status=running)" \
  "grep -q '\"status\": \"running\"' \"\$LJ6\""
check "6b. …and the readout names the discovered target" \
  "[ -n \"\$(printf '%s' \"\$OUT6\" | grep -F 'the fixture app')\" ]"
check "6c. …and the honest inspection raised NO fence breach" \
  "[ -z \"\$(printf '%s' \"\$OUT6\" | grep -i 'fence breach')\" ]"
( cd "$R6" && LCARS_LAUNCH_ROOT="$L6" LCARS_WORKER_BIN="$TMPROOT/ins6/claude" \
    bash "$LAUNCH_SH" m6 --stop >/dev/null 2>&1 )
[ -n "$P6" ] && { kill -KILL -"$P6" 2>/dev/null || kill -KILL "$P6" 2>/dev/null; } || true

R6b="$(mk_repo6 m6b)"
L6b="$TMPROOT_P/lroot6b"
mk_dirty_inspector "$TMPROOT/ins6b" "$L6b/m6b"
OUT6B="$( cd "$R6b" && LCARS_LAUNCH_ROOT="$L6b" LCARS_WORKER_BIN="$TMPROOT/ins6b/claude" \
    LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m6b 2>&1 )"; RC6B=$?
LJ6B="$R6b/.git/lcars/missions/m6b/launch.json"
check "6d. an inspector that dirties the checkout FAILS the launch (non-zero)" \
  "[ \"\$RC6B\" != '0' ]"
check "6e. …and says so as a fence breach, naming the file" \
  "[ -n \"\$(printf '%s' \"\$OUT6B\" | grep -i 'fence breach')\" ] && [ -n \"\$(printf '%s' \"\$OUT6B\" | grep -F 'app.txt')\" ]"
check "6f. …and NOTHING was launched (no running record)" \
  "! grep -q '\"status\": \"running\"' \"\$LJ6B\""
check "6g. …and the record a human reads carries the reason" \
  "grep -qF 'MODIFIED the checkout' \"\$LJ6B\""
check "6h. …and the edit is STILL THERE — never silently reverted" \
  "grep -q 'the inspector edited this' \"$L6b/m6b/app.txt\""
check "6i. no real CLI was ever spawned" 'no_spend'

# ============================================================================
# 7. THE FRONT-HALF WORKTREE — a stray write into the captain's CODE is a breach
# ============================================================================
# WHY. MEASURED LIVE, claude/sonnet, 2026-08-30 (tests/drives/s168-runs/): the
# `default` role's deny list DID stop a write, but `repo-read` — the front-half
# toolset — KEEPS Write on purpose, because writing its answer file is how the
# Stage returns its result, and on claude the Write tool is NOT SCOPED TO A
# DIRECTORY. A repo-read worker was measured writing at an ARBITRARY ABSOLUTE
# PATH. Section 5 fences the Mission's STATE; this section fences the Mission's
# CODE — the isolated front-half worktree that Research / Validate / Plan /
# Plan Review read from and that every worker they spawn inherits as cwd.
#
# EVERY drive here goes through the REAL `research` Stage driver, so it exercises
# the production wiring (cmd_research → enter_mission_worktree → spawn_worker →
# worker_spawn), not a bench rig — except 7l/7m, whose repo-write exemption needs
# a role the production spawn-stage surface hard-codes, and which therefore use
# the same "mutate a copy to prove the mechanism" idiom as sections 3 and 5m.
printf '\n  -- 7. the front-half worktree: a stray write into the Mission code is a breach --\n'

mk_repo7() { # → repo dir, mission parked at align on its own branch
  local repo; repo="$(mktemp -d "$TMPROOT/r7.XXXX")"
  (
    cd "$repo"
    git init -q -b main; git config user.email t@t; git config user.name t
    mkdir src; printf 'base\n' >src/base.txt; printf '# Context\n' >CONTEXT.md
    git add -A; git commit -q -m init
    git checkout -q -b "lcars/$MID"; printf 'm\n' >src/m.txt; git add -A; git commit -q -m mission
    git checkout -q main
  ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/$MID"; mkdir -p "$d"
  printf '{ "projectName": "fixture" }\n' >"$repo/.git/lcars/config.json"
  cat >"$d/state.json" <<JSON
{ "id": "$MID", "type": "feature", "title": "t", "stage": "align",
  "branch": "lcars/$MID", "base": "main", "githubIssue": null }
JSON
  printf '# Mission\n\n**Goal:** something.\n' >"$d/prd.md"
  printf '{"ts":1,"mission":"%s","stage":"align","type":"seed","detail":"x"}\n' "$MID" >"$d/events.jsonl"
  printf '#!/usr/bin/env bash\nexit 96\n' >"$repo.worker"; chmod +x "$repo.worker"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo.gh"; chmod +x "$repo.gh"
  printf '%s\n' "$repo"
}

# One adapter for the whole section. It answers Research honestly (one question,
# one well-formed response — so the drive really does spawn TWO cold workers and
# reach `advance`), and it is the WORKER'S HANDS: $STRAY makes it create a file
# in its cwd, $TOUCH makes it edit a tracked file there. It also records the
# porcelain AS THE WORKER SAW IT, which is what turns 7j into a proof.
ADAPTER7="$TMPROOT/adapter7.sh"
cat >"$ADAPTER7" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"
[ "$sub" = "spawn" ] || exit 0
[ -n "${PORCELAIN_AT_SPAWN:-}" ] && git status --porcelain >>"$PORCELAIN_AT_SPAWN" 2>/dev/null
[ -n "${STRAY:-}" ] && printf 'a note the worker had no business writing\n' >"$PWD/$STRAY"
[ -n "${TOUCH:-}" ] && printf 'edited by the worker\n' >>"$PWD/$TOUCH"
mkdir -p "$outdir"
case "$role" in
  research-questions) printf 'Which datastore should the cache use?\n' >"$outdir/questions.txt" ;;
  research-agent)
    cat >"$outdir/response.json" <<'JSON'
{ "question": "Which datastore should the cache use?",
  "recommendation": "use the existing store",
  "supporting_points": ["it is already wired"], "confidence": "high" }
JSON
    ;;
esac
exit 0
EOF
chmod +x "$ADAPTER7"

research7() { # repo [script] [env…]   → OUT7 / RC7
  local repo="$1" script="${2:-$SCRIPT}"; shift 2
  OUT7="$( cd "$repo" && env LCARS_GH_BIN="$repo.gh" LCARS_WORKER_BIN="$repo.worker" \
      LCARS_WORKER_ADAPTER="$ADAPTER7" LCARS_WORKER_CLI=claude \
      LCARS_USAGE_CAPTURE=0 LCARS_NOW=1700000000 "$@" \
      bash "$script" research --mission "$MID" 2>&1 )"
  RC7=$?
}
# The manifest of a mission dir: every file, hashed, keyed by its path RELATIVE
# to the mission dir — so two runs in two different temp repos are comparable.
manifest7() { # mission-dir → path<TAB>hash lines on stdout
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\t%s\n' "$f" "$(shasum -a 256 "$f" | awk '{print $1}')"
    done )
}

# --- 7a. a worker that CREATES a file in the mission checkout ---------------
r7a="$(mk_repo7)"
research7 "$r7a" "$SCRIPT" STRAY=notes.txt
E7A="$r7a/.git/lcars/missions/$MID/events.jsonl"
check "7a. a repo-read worker that writes a stray file into the front-half worktree FAILS THE STAGE" \
  "[ \"\$RC7\" != '0' ]"
check "7b. …and emits a worker_fence_breach event" "grep -q worker_fence_breach \"\$E7A\""
check "7c. …NAMING the file it wrote" \
  "[ -n \"\$(grep worker_fence_breach \"\$E7A\" | grep -F 'notes.txt')\" ]"
check "7d. …and the readout says the Mission's CODE was written, not just 'state'" \
  "[ -n \"\$(printf '%s' \"\$OUT7\" | grep -i 'fence breach')\" ] && [ -n \"\$(printf '%s' \"\$OUT7\" | grep -iF \"the Mission's code\")\" ]"
check "7e. …and nothing was repaired — the Stage never advanced past align" \
  "[ -n \"\$(printf '%s' \"\$OUT7\" | grep -i 'nothing has been repaired')\" ] && [ -n \"\$(grep -F '\"stage\": \"align\"' \"\$r7a/.git/lcars/missions/$MID/state.json\")\" ]"

# --- 7f. a worker that MODIFIES AN EXISTING TRACKED FILE ---------------------
# The other half of the shape: not a new path, an edit to code that was already
# there and clean. Caught by the porcelain code changing, not by the path being new.
r7f="$(mk_repo7)"
research7 "$r7f" "$SCRIPT" TOUCH=src/base.txt
E7F="$r7f/.git/lcars/missions/$MID/events.jsonl"
check "7f. a repo-read worker that MODIFIES a tracked file in the worktree is a breach too" \
  "[ \"\$RC7\" != '0' ]"
check "7g. …naming that tracked file" \
  "[ -n \"\$(grep worker_fence_breach \"\$E7F\" | grep -F 'src/base.txt')\" ]"

# --- 7h. THE NO-OP CASE, proved rather than asserted -------------------------
# "Byte-identical to before the change" needs a BEFORE to compare against, so we
# build one: a copy of the shipped run.sh with the worktree half of the snapshot
# REMOVED. 7i proves that copy really is the old behaviour (it lets the 7a stray
# write through); 7j/7k then show the shipped script's honest run is
# indistinguishable from it, file for file.
RUNPRE="$TMPROOT/run-pre-wtfence.sh"
sed 's|^  worker_fence_wt_snapshot$|  : # worktree half REMOVED — the pre-change behaviour|' \
  "$SCRIPT" >"$RUNPRE"
check "7h. (setup) the pre-change copy really has the worktree half removed" \
  "[ \"\$(grep -c 'worktree half REMOVED' \"\$RUNPRE\")\" = '1' ] && ! grep -qx '  worker_fence_wt_snapshot' \"\$RUNPRE\""
r7i="$(mk_repo7)"
research7 "$r7i" "$RUNPRE" STRAY=notes.txt
check "7i. (setup) …and it is genuinely BLIND to the stray write — the same drive passes under it" \
  "[ \"\$RC7\" = '0' ] && ! grep -q worker_fence_breach \"\$r7i/.git/lcars/missions/$MID/events.jsonl\""

r7j="$(mk_repo7)"; research7 "$r7j" "$SCRIPT"; RC7J="$RC7"
r7k="$(mk_repo7)"; research7 "$r7k" "$RUNPRE"
manifest7 "$r7j/.git/lcars/missions/$MID" >"$TMPROOT/m7.shipped"
manifest7 "$r7k/.git/lcars/missions/$MID" >"$TMPROOT/m7.pre"
check "7j. an honest Stage — two cold workers, output only in its outdir — exits ZERO under the new fence" \
  "[ \"\$RC7J\" = '0' ] && [ \"\$RC7\" = '0' ]"
check "7k. …and emits NO breach" \
  "! grep -q worker_fence_breach \"\$r7j/.git/lcars/missions/$MID/events.jsonl\""
check "7l. …and its events.jsonl is BYTE-IDENTICAL to the pre-change script's" \
  "cmp -s \"\$r7j/.git/lcars/missions/$MID/events.jsonl\" \"\$r7k/.git/lcars/missions/$MID/events.jsonl\""
check "7m. …and so is EVERY file in the mission dir, path for path and byte for byte" \
  "diff -q \"\$TMPROOT/m7.shipped\" \"\$TMPROOT/m7.pre\" >/dev/null"
check "7n. (guard) that manifest is not vacuously empty — the honest drive really produced artifacts" \
  "[ \"\$(wc -l <\"\$TMPROOT/m7.shipped\" | tr -d ' ')\" -ge 4 ] && grep -q 'research/1.json' \"\$TMPROOT/m7.shipped\""

# --- 7o. THE FALSE-FIRE GUARD — a tree dirtied BEFORE the worker ever ran -----
# This is the reason the audit is a BASELINE DIFF and not an is-it-empty check
# (launch.sh's lesson, and provisioning is exactly how it bites: a repo's
# worktreeSetupCommand can touch a lockfile). Here a `post-checkout` hook stands
# in for provisioning — git runs it as `worktree add` checks the branch out, so
# the tree is dirty before any worker exists. The adapter records the porcelain
# IT saw, so 7o proves the dirt was really there rather than assuming it.
r7o="$(mk_repo7)"
mkdir -p "$r7o/.git/hooks"
cat >"$r7o/.git/hooks/post-checkout" <<'HOOK'
#!/usr/bin/env bash
# stand-in for a repo's worktreeSetupCommand: provisioning dirties the tree
printf 'lock\n' >"$PWD/provisioned.lock"
printf 'touched by provisioning\n' >>"$PWD/src/base.txt"
exit 0
HOOK
chmod +x "$r7o/.git/hooks/post-checkout"
: >"$TMPROOT/porcelain7"
research7 "$r7o" "$SCRIPT" PORCELAIN_AT_SPAWN="$TMPROOT/porcelain7"
check "7o. (setup) the worker really did see a DIRTY tree — an is-it-empty check would have fired here" \
  "[ -s \"\$TMPROOT/porcelain7\" ] && [ -n \"\$(grep -F 'provisioned.lock' \"\$TMPROOT/porcelain7\")\" ] && [ -n \"\$(grep -F 'src/base.txt' \"\$TMPROOT/porcelain7\")\" ]"
check "7p. …and the HONEST worker in that dirty tree raises NO breach and the Stage exits ZERO" \
  "[ \"\$RC7\" = '0' ] && ! grep -q worker_fence_breach \"\$r7o/.git/lcars/missions/$MID/events.jsonl\""

# --- 7q. the repo-write exemption still holds INSIDE a front-half worktree ----
# repo-write is the Implementer: writing is its job, and it is contained by the
# worktree + declared edits + the post-commit scope check + flip-flop instead.
# Production's `spawn-stage` surface enters no worktree and hard-codes the
# repo-read toolset, so — exactly as 5m does — a mutated copy threads both.
RUNWT="$TMPROOT/run-wt-rolepass.sh"
sed -e 's|  local outdir; outdir="$(mktemp -d)"|  enter_mission_worktree "${LCARS_TEST_WT_REF:-}" spawn-stage; local outdir; outdir="$(mktemp -d)"|' \
    -e 's|LCARS_WORKER_ROLE="$role" worker_spawn "repo-read" "$outdir" "test prompt"|LCARS_WORKER_ROLE="$role" worker_spawn "$role" "$outdir" "test prompt"|' \
  "$SCRIPT" >"$RUNWT"
check "7q. (setup) the copy both ENTERS a front-half worktree and threads the role to the toolset" \
  "[ \"\$(grep -c 'LCARS_TEST_WT_REF' \"\$RUNWT\")\" = '1' ] && grep -q 'worker_spawn \"\$role\" \"\$outdir\" \"test prompt\"' \"\$RUNWT\""
mkdir -p "$TMPROOT/stub7"
cat >"$TMPROOT/stub7/claude" <<'EOF'
#!/usr/bin/env bash
[ -n "${STRAY:-}" ] && printf 'written freely\n' >"$PWD/$STRAY"
exit 0
EOF
chmod +x "$TMPROOT/stub7/claude"
wt_spawn7() { # repo role → RC7
  local repo="$1" role="$2"
  OUT7="$( cd "$repo" && env LCARS_WORKER_BIN="$TMPROOT/stub7/claude" \
      LCARS_WORKER_ADAPTER="$ADAPTER" LCARS_USAGE_CAPTURE=0 LCARS_NOW=1700000000 \
      LCARS_TEST_WT_REF="lcars/$MID" STRAY=written.txt \
      bash "$RUNWT" spawn-stage --mission "$MID" "$role" 2>&1 )"
  RC7=$?
}
r7r="$(mk_repo7)"; wt_spawn7 "$r7r" repo-write
check "7r. a repo-write worker writing freely in a front-half worktree is NOT a breach — exempt by design" \
  "[ \"\$RC7\" = '0' ] && [ -z \"\$(printf '%s' \"\$OUT7\" | grep -i 'fence breach')\" ]"
check "7r2. (guard) …and the worktree was really entered and really written to" \
  "[ -n \"\$(printf '%s' \"\$OUT7\" | grep -F 'in an isolated worktree')\" ]"
r7s="$(mk_repo7)"; wt_spawn7 "$r7s" repo-read
check "7s. (control) the SAME stub under the repo-read toolset IS a breach" \
  "[ \"\$RC7\" != '0' ] && [ -n \"\$(printf '%s' \"\$OUT7\" | grep -F 'written.txt')\" ]"

check "7t. no real CLI was ever spawned" 'no_spend'

printf '\n\033[1mworker fence:\033[0m \033[32m%s passed\033[0m, \033[31m%s failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
