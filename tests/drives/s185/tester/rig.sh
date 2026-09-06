#!/usr/bin/env bash
# S185 FRESH-TESTER RIG (captain stand-in). Zero spend, real repos, real runner.
#
# `fuse` + the counting-shim contract are INHERITED VERBATIM from
# tests/drives/s183b/rig.sh (which itself inherits S182's). Never
# $LCARS_WORKER_BIN (S159: it loses to a persisted state.json workerBin).
set -u

LCARS_SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
RUN_SH="$LCARS_SRC/skills/lcars-run/run.sh"
APPROVE_SH="$LCARS_SRC/skills/lcars-approve/approve.sh"
FILE_SH="$LCARS_SRC/skills/lcars-file/file.sh"
GATE_SH="$LCARS_SRC/skills/lcars-init/foundation-gate.sh"
READINESS_SH="$LCARS_SRC/skills/lcars-init/readiness.sh"

FIX_ROOT="${FIX_ROOT:-${TMPDIR:-/tmp}lcars-s185}"
FIX_ROOT="${FIX_ROOT%/}"
mkdir -p "$FIX_ROOT"
SPEND="${SPEND:-$FIX_ROOT/spend.log}"
[ -f "$SPEND" ] || : > "$SPEND"

# --- SPEND FUSE (s183b/rig.sh, verbatim) ------------------------------------
fuse() {
  local sh="${1:-}"
  if [ -n "$sh" ] && [ -x "$sh/claude" ] && [ -x "$sh/copilot" ]; then return 0; fi
  echo "SPEND FUSE TRIPPED: no counting claude/copilot at '${sh:-<empty>}' — REFUSING (would bill)" >&2
  return 1
}
spawns()   { awk -F'\t' '/^SPAWN/{n++} END{print n+0}' "$SPEND" 2>/dev/null || echo 0; }
billable() { awk -F'\t' '/^SPAWN/ && $0 ~ /--model/{n++} END{print n+0}' "$SPEND" 2>/dev/null || echo 0; }

# S185 fix round 1 — an ESCAPE-AWARE jq-free reader (mirrors run.sh's json_str).
# The naive `sed 's/.*"key"[^"]*"\([^"]*\)".*/\1/p'` stops at the FIRST
# escaped quote, and EVERY command the real detector emits embeds one — so this
# harness was printing (and, in the by-hand leg, RUNNING) a truncated fragment.
tc_of() { # file -> its testCommand, unescaped
  sed -En 's/.*"testCommand"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' "$1" \
    | head -1 | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# --- the SCRIPTED counting worker -------------------------------------------
# Counts EVERY spawn (and flags any that carried --model, i.e. would have
# billed) to $SPEND, then dispatches to a per-ticket behaviour script under
# $BEHAV/<ticket>.sh, run with cwd = the worker's tree and $out = LCARS_WORK_OUT.
make_worker_shim() { # shim-dir behaviour-dir
  local d="$1" behav="$2" b
  mkdir -p "$d"
  for b in claude copilot; do
    cat > "$d/$b" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --version "*|*" -v "*)
     printf 'PROBE\t%s\t--version\n' "\$(basename "\$0")" >> "$SPEND"
     echo "0.0.0-s185-tester-fake (counting shim)"; exit 0 ;;
esac
printf 'SPAWN\t%s\t%s\t%s\n' "\$(basename "\$0")" "\${LCARS_WORKER_ROLE:-?}" "\$(printf '%s' "\$*" | tr '\n' ' ' | head -c 200)" >> "$SPEND"
out="\${LCARS_WORK_OUT:-}"
[ -n "\$out" ] || exit 0
prompt="\$2"
tid="\$(printf '%s\n' "\$prompt" | awk '/^## Your ticket\$/{getline; print; exit}' | grep -oE 't-[0-9]+' | head -1)"
mkdir -p "$behav/prompts"
printf '%s\n' "\$prompt" > "$behav/prompts/\${LCARS_WORKER_ROLE:-role}.\${tid:-none}.txt" 2>/dev/null || :
[ "\${LCARS_WORKER_ROLE:-}" = implement-tdd ] || exit 0
if [ -n "\$tid" ] && [ -x "$behav/\$tid.sh" ]; then
  out="\$out" TID="\$tid" bash "$behav/\$tid.sh"
fi
exit 0
SH
    chmod +x "$d/$b"
  done
}

# --- fixtures ---------------------------------------------------------------
# A pristine template repo built ONCE under FIX_ROOT and COPIED per drive
# (reuse, don't delete — the template survives).
template_blank() { # → path to the gf-blank template
  local p="$FIX_ROOT/gf-blank"
  if [ ! -d "$p/.git" ]; then
    mkdir -p "$p"
    git -C "$p" init -q
    git -C "$p" config user.email t@e.x; git -C "$p" config user.name t
    git -C "$p" config commit.gpgsign false
    printf '# gf-blank\n\nA blank project — no code, no tests.\n' > "$p/README.md"
    printf '# ctx\nA day-zero repo.\n' > "$p/CONTEXT.md"
    git -C "$p" add -A >/dev/null 2>&1
    git -C "$p" commit -qm "initial commit" >/dev/null 2>&1
    mkdir -p "$p/.git/lcars/missions"
    printf '{\n  "version": 1\n}\n' > "$p/.git/lcars/config.json"
  fi
  printf '%s' "$p"
}

workcopy() { # template name → a fresh working copy path
  local t="$1" n="$2"; local p="$FIX_ROOT/work/$n"
  rm -rf "$p"; mkdir -p "$FIX_ROOT/work"
  cp -R "$t" "$p"
  git -C "$p" config user.email t@e.x; git -C "$p" config user.name t
  git -C "$p" config commit.gpgsign false
  # a copied repo can carry stale worktree registrations
  git -C "$p" worktree prune >/dev/null 2>&1 || :
  printf '%s' "$p"
}

# Plant an INITIALIZATION mission at implement, with N tickets.
plant_mission() { # repo mission-id [ticket-ids...]
  local r="$1" mid="$2"; shift 2
  local md="$r/.git/lcars/missions/$mid"
  mkdir -p "$md/tickets" "$md/manifests"
  local base; base="$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null || echo main)"
  cat > "$md/state.json" <<JSON
{
  "id": "$mid",
  "missionType": "initialization",
  "type": "feature",
  "title": "Establish the foundation",
  "stage": "implement",
  "branch": "lcars/$mid",
  "base": "$base",
  "workerBin": "claude",
  "workerCli": "claude"
}
JSON
  cat > "$md/prd.md" <<'MD'
# Mission: Establish the foundation
**Type:** feature
**Goal:** A running skeleton with a working test system.
**Acceptance Criteria:**
- one command runs the suite
MD
  {
    echo '['
    local i=0
    local t
    for t in "$@"; do
      [ "$i" -gt 0 ] && echo ','
      echo '  {'
      printf '    "id": "%s",\n' "$t"
      printf '    "title": "ticket %s",\n' "$t"
      printf '    "description": "one slice",\n'
      printf '    "acceptanceCriteria": ["it works"],\n'
      printf '    "dependencies": []\n'
      printf '  }'
      i=$((i+1))
    done
    echo; echo ']'
  } > "$md/approved-plan.json"
  cp "$md/approved-plan.json" "$md/plan.json"
  {
    echo '['
    local w=0
    local t2
    for t2 in "$@"; do
      w=$((w+1))
      [ "$w" -gt 1 ] && echo ','
      echo '  {'
      printf '    "wave": %d,\n' "$w"
      echo '    "tickets": ['
      echo '      {'
      printf '        "id": "%s",\n' "$t2"
      printf '        "issue": null\n'
      echo '      }'
      echo '    ]'
      printf '  }'
    done
    echo; echo ']'
  } > "$md/waves.json"
  for t in "$@"; do printf '## Relevant files\n- src/%s.js\n' "$t" > "$md/manifests/$t.md"; done
  printf '%s' "$md"
}

# --- drives ------------------------------------------------------------------
stage_drive() { # repo shim mission [extra env pairs...] → OUT/RC
  local r="$1" sh="$2" mid="$3"; shift 3
  fuse "$sh" || { RC=99; OUT="REFUSED-BY-FUSE"; return 0; }
  OUT="$( cd "$r" && env PATH="$sh:$PATH" \
            LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
            LCARS_WORKER_TRIES=1 LCARS_EMPTY_WORKER_TRIES=1 \
            LCARS_SETUP_INSTALL_TIMEOUT_SECS=600 \
            LCARS_VERSION_CHECK=0 \
            "$@" bash "$RUN_SH" implement --mission "$mid" 2>&1 )"
  RC=$?
}

run_sub() { # repo shim -- argv…  (any run.sh subcommand, under the fuse)
  local r="$1" sh="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  fuse "$sh" || { RC=99; OUT="REFUSED-BY-FUSE"; return 0; }
  OUT="$( cd "$r" && env PATH="$sh:$PATH" LCARS_GH_BIN=true \
            LCARS_GIT_BIN="$(command -v git)" LCARS_VERSION_CHECK=0 "$@" 2>&1 )"
  RC=$?
}

gate()     { ( cd "$1" && bash "$GATE_SH" 2>&1; echo "GATE_RC=$?" ); }
verdict()  { ( cd "$1" && bash "$READINESS_SH" --json 2>/dev/null ); }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok  \033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
note(){ printf '  ·     %s\n' "$1"; }
