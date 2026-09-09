#!/usr/bin/env bash
# S189 TESTER RIG — the REAL surface: real gh, the real private fixture repo
# roferg/lcars-mp-fixture, and TWO real local clones of it ("laptop A" and
# "laptop B"). Inherited from tests/drives/s188/lib.sh — same zero-spend fuse,
# same PATH shims for BOTH `claude` and `copilot`. THE DIFFERENCE: `gh` is NOT
# stubbed here. These drives talk to github.com.
#
# ZERO MODEL SPEND is still absolute: the worker CLIs are shims, so no stage
# ever bills. `spawns` / `billable` report it at the end of every drive.
#
# Env:
#   LCARS_SRC        the LCARS checkout under test  (default: the captain's)
#   S189_FIXTURE     owner/repo of the fixture       (default: roferg/lcars-mp-fixture)
#   S189_HOME        where the clones live (persisted across drives so the two
#                    laptops survive between runs)
set -uo pipefail
export LCARS_VERSION_CHECK=0

LCARS_SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
FILE_SH="$LCARS_SRC/skills/lcars-file/file.sh"
RUN_SH="$LCARS_SRC/skills/lcars-run/run.sh"
FEEDBACK_SH="$LCARS_SRC/skills/lcars-feedback/feedback.sh"
APPROVE_SH="$LCARS_SRC/skills/lcars-approve/approve.sh"
RESPOND_SH="$LCARS_SRC/skills/lcars-respond/respond.sh"
LOG_SH="$LCARS_SRC/skills/lcars-log/log.sh"
STATUS_SH="$LCARS_SRC/skills/lcars-status/status.sh"
BUDDY_SH="$LCARS_SRC/skills/lcars-buddy/buddy.sh"
ADOPT_SH="$LCARS_SRC/skills/lcars-adopt/adopt.sh"
ADAPTER="$LCARS_SRC/skills/lcars-run/host-adapter.sh"

FIXTURE="${S189_FIXTURE:-roferg/lcars-mp-fixture}"
S189_HOME="${S189_HOME:-${TMPDIR:-/tmp}/s189}"
mkdir -p "$S189_HOME"
WORK="${WORK:-$(mktemp -d "$S189_HOME/run.XXXXXX")}"
export WORK

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
note(){ printf '  ·    %s\n' "$1"; }
hdr() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- spend fuse
# Byte-for-byte the S188 fuse. BOTH engines shimmed; anything carrying --model
# is recorded as BILLABLE (which, on a shim, means "would have billed").
SHIM="$WORK/shim"; SPEND="$WORK/spend.log"; BILLABLE="$WORK/billable.log"
mkdir -p "$SHIM"; : >"$SPEND"; : >"$BILLABLE"
mk_shim() { # engine-name
cat >"$SHIM/$1" <<WORKER
#!/usr/bin/env bash
_mdl=no
for a in "\$@"; do case "\$a" in --model|-m|--model=*) _mdl=yes ;; esac; done
printf 'SPAWN\t%s\tmodel=%s\trole=%s\n' "$1" "\$_mdl" "\${LCARS_WORKER_ROLE:-?}" >> "$SPEND"
[ "\$_mdl" = yes ] && printf 'BILLABLE\t%s\n' "$1" >> "$BILLABLE"
case " \$* " in *" --version "*|*" -v "*) echo "0.0.0-s189-fake"; exit 0 ;; esac
exit 0
WORKER
chmod +x "$SHIM/$1"
}
mk_shim claude; mk_shim copilot
[ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] || { echo "SPEND FUSE TRIPPED"; exit 1; }
export PATH="$SHIM:$PATH"
spawns()   { local n; n=$(grep -c "^SPAWN" "$SPEND" 2>/dev/null); printf "%s" "${n:-0}"; }
billable() { local n; n=$(grep -c "^BILLABLE" "$BILLABLE" 2>/dev/null); printf "%s" "${n:-0}"; }

# ---------------------------------------------------------------- real gh
# A thin RECORDING PASSTHROUGH: every argv is logged, then the real gh runs.
# It exists so a drive can prove WHICH forge calls a verb made without changing
# what those calls do.
GH_REAL="$(command -v gh)"
GH_LOG="$WORK/gh.log"; export GH_LOG
: >"$GH_LOG"
cat >"$WORK/gh-rec" <<REC
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"$GH_LOG"
exec "$GH_REAL" "\$@"
REC
chmod +x "$WORK/gh-rec"
export LCARS_GH_BIN="$WORK/gh-rec"
gh_calls() { local n; n=$(grep -c "^gh " "$GH_LOG" 2>/dev/null); printf "%s" "${n:-0}"; }

# ------------------------------------------- estimator: real render, fake est
# Identical to S188's: only the `estimate` subcommand is faked (it would spawn a
# model); every other subcommand goes to the REAL run.sh.
EST_STUB="$WORK/estimate-run.sh"
cat >"$EST_STUB" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" != "estimate" ]; then exec bash "$RUN_SH" "\$@"; fi
shift
mid=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --mission) mid="\${2:-}"; shift 2 ;;
    --mission=*) mid="\${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
gitdir="\$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
case "\$gitdir" in /*) : ;; *) gitdir="\$PWD/\$gitdir" ;; esac
mdir="\$gitdir/lcars/missions/\$mid"
[ -d "\$mdir" ] || exit 1
cat >"\$mdir/estimate.json" <<JSON
{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "medium",
  "models": { "research": "sonnet", "validate": "sonnet", "plan": "sonnet",
  "planReview": "sonnet", "implement": "opus", "verify": "sonnet" },
  "deviations": [], "estimatorModel": "opus" }
JSON
exit 0
EOF
chmod +x "$EST_STUB"
export LCARS_RUN_BIN="$EST_STUB"

# ------------------------------------------------- state.json edits, LCARS-style
st_set_str() { sed -i '' "s|\(\"$2\"[[:space:]]*:[[:space:]]*\"\)[^\"]*\(\"\)|\1$3\2|" "$1"; }
st_add() { local f="$1" line="$2" tmp; tmp="$(mktemp)"
  awk -v L="  $line," 'NR==1{print; print L; next} {print}' "$f" >"$tmp" && mv "$tmp" "$f"; }
st_get() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
st_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }

# ---------------------------------------------------------------- the laptops
# TWO REAL CLONES of the private fixture repo. `git clone -b main` (never a bare
# init) — the S189 leg-B trap: a bare repo left on an unborn `master` checks out
# nothing, and a branch cut there is an ORPHAN, which makes every "is the base
# ahead?" check answer YES and silently diverts approve into reconcile.
laptop() { # <name> → path (idempotent: reuses an existing clone)
  local name="$1" dir
  dir="$S189_HOME/$name"
  if [ ! -d "$dir/.git" ]; then
    git clone -q -b main "https://github.com/$FIXTURE.git" "$dir" || return 1
  fi
  ( cd "$dir" && git config user.email roganscottferguson@gmail.com \
      && git config user.name "Rogan Ferguson" ) >/dev/null 2>&1
  printf '%s' "$dir"
}

# lcars_config <clone> — the .git/lcars a real `lcars init` leaves behind, minus
# the interactive vision gate. The LABEL SET is created on the fixture separately
# (once) by setup.sh.
lcars_config() { # <clone>
  local repo="$1"
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<JSON
{ "model": "claude-sonnet", "projectName": "lcars-mp-fixture", "contextFile": "CONTEXT.md", "testCommand": "bash tests/t.sh", "testCommandSource": "configured", "created": "2026-09-08T00:00:00Z" }
JSON
}

# reset_laptop <clone> — wipe LCARS state + local branches, back to origin/main.
reset_laptop() { # <clone>
  local repo="$1"
  rm -rf "$repo/.git/lcars"
  ( cd "$repo" && git checkout -q main 2>/dev/null
    git branch 2>/dev/null | tr -d ' *' | grep -v '^main$' | while read -r b; do
      [ -n "$b" ] && git branch -qD "$b" >/dev/null 2>&1
    done
    git fetch -q --prune origin >/dev/null 2>&1
    git reset -q --hard origin/main >/dev/null 2>&1 ) >/dev/null 2>&1
}

host() { LCARS_GH_BIN="$LCARS_GH_BIN" bash "$ADAPTER" "$@" </dev/null; }

# hostin <clone> <op> [args…] — the adapter run INSIDE a clone. `gh issue view`
# resolves the repo from the CWD's remote, so an adapter call made from anywhere
# else silently answers about a DIFFERENT repository. (The tester learned this
# the expensive way: a read-back run from the LCARS checkout reported an
# unassigned issue that GitHub had assigned correctly.)
hostin() { local d="$1"; shift; ( cd "$d" && LCARS_GH_BIN="$LCARS_GH_BIN" bash "$ADAPTER" "$@" </dev/null ); }

# fixture_drop_branch <branch> — delete the branch from the FIXTURE remote if it
# is there. A re-run of a drive cuts the same mission branch again from a fresh
# base, so a leftover remote head from the previous run makes `open_pr`'s push a
# non-fast-forward and the drive dies with a misleading "could not push".
fixture_drop_branch() { # <branch>
  "$GH_REAL" api -X DELETE "repos/$FIXTURE/git/refs/heads/$1" >/dev/null 2>&1 || true
}
