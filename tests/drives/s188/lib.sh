#!/usr/bin/env bash
# S188 TESTER RIG — shared fixture + stubs. Sourced by the drive scripts.
# ZERO model spend: PATH shims for BOTH `claude` and `copilot`, behind a fuse.
set -uo pipefail
export LCARS_VERSION_CHECK=0

LCARS_SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
FILE_SH="$LCARS_SRC/skills/lcars-file/file.sh"
RUN_SH="$LCARS_SRC/skills/lcars-run/run.sh"
FEEDBACK_SH="$LCARS_SRC/skills/lcars-feedback/feedback.sh"

WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/s188tester.XXXXXX")}"
export WORK
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
note(){ printf '  ·    %s\n' "$1"; }
hdr() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- spend fuse
SHIM="$WORK/shim"; SPEND="$WORK/spend.log"; BILLABLE="$WORK/billable.log"
mkdir -p "$SHIM"; : >"$SPEND"; : >"$BILLABLE"
mk_shim() { # engine-name
cat >"$SHIM/$1" <<WORKER
#!/usr/bin/env bash
_mdl=no
for a in "\$@"; do case "\$a" in --model|-m|--model=*) _mdl=yes ;; esac; done
printf 'SPAWN\t%s\tmodel=%s\trole=%s\n' "$1" "\$_mdl" "\${LCARS_WORKER_ROLE:-?}" >> "$SPEND"
[ "\$_mdl" = yes ] && printf 'BILLABLE\t%s\n' "$1" >> "$BILLABLE"
case " \$* " in *" --version "*|*" -v "*) echo "0.0.0-s188-fake"; exit 0 ;; esac
exit 0
WORKER
chmod +x "$SHIM/$1"
}
mk_shim claude; mk_shim copilot
[ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] || { echo "SPEND FUSE TRIPPED"; exit 1; }
export PATH="$SHIM:$PATH"
spawns() { local n; n=$(grep -c "^SPAWN" "$SPEND" 2>/dev/null); printf "%s" "${n:-0}"; }
billable() { local n; n=$(grep -c "^BILLABLE" "$BILLABLE" 2>/dev/null); printf "%s" "${n:-0}"; }

# ---------------------------------------------------------------- gh stub
GH_STUB="$WORK/gh"
GH_LOG="$WORK/gh.log";   export GH_LOG
BODIES="$WORK/bodies";   export BODIES
mkdir -p "$BODIES"; : >"$GH_LOG"
cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
n=$(ls "$BODIES" 2>/dev/null | grep -c -v '\.argv$')
printf 'gh %s\n' "$*" >>"$GH_LOG"
kind="other"
case "$1 $2" in
  "issue create") kind="issue-create" ;;
  "issue edit")   kind="issue-edit" ;;
  "issue comment") kind="issue-comment" ;;
esac
case "$*" in
  *"issues/"*"/comments"*) kind="comment-create" ;;
  *"issues/comments/"*)    kind="comment-edit" ;;
esac
seq=$(printf '%03d' "$((n+1))")
got=0; prev=""
out="$BODIES/$seq.$kind"
for a in "$@"; do
  # BYTE-EXACT capture: cp / cat > file, NEVER $(cat) (which eats trailing NLs).
  if [ "$prev" = "--body-file" ]; then
    if [ "$a" = "-" ]; then cat >"$out"; else cp "$a" "$out"; fi; got=1
  fi
  if [ "$prev" = "--body" ]; then printf '%s' "$a" >"$out"; got=1; fi
  case "$a" in body=@-) cat >"$out"; got=1 ;; esac
  prev="$a"
done
if [ "$got" = 1 ]; then printf 'gh %s\n' "$*" >"$out.argv"; fi
case "$1 $2" in
  "issue create") echo "https://github.com/owner/repo/issues/${LCARS_STUB_ISSUE:-42}"; exit ${LCARS_STUB_CREATE_RC:-0} ;;
  "issue edit")   exit ${LCARS_STUB_EDIT_RC:-0} ;;
esac
case "$*" in
  *"--method POST"*"/comments"*) echo '{"id":9001,"user":{"id":777}}'; exit 0 ;;
  *"--method PATCH"*)            echo '{"id":9001}'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$GH_STUB"
export LCARS_GH_BIN="$GH_STUB"
body_edits() { local n; n=$(grep -c "^gh issue edit .* --body-file" "$GH_LOG" 2>/dev/null); printf "%s" "${n:-0}"; }

# ------------------------------------------- estimator: real render, fake est
# `estimate` writes a deterministic estimate.json (no model). EVERY other
# subcommand — render-estimate above all — goes to the REAL run.sh, so the
# "## Estimate" section in the body is the product's own renderer.
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
# NEVER rewrite state.json with a JSON pretty-printer: run.sh/feedback.sh edit it
# LINE-WISE with sed/grep, so a reflowed file gets shredded. These are the same
# one-line-per-key edits the product itself makes.
st_set_str() { sed -i '' "s|\(\"$2\"[[:space:]]*:[[:space:]]*\"\)[^\"]*\(\"\)|\1$3\2|" "$1"; }
st_add() { # file  raw-json-line-without-trailing-comma
  local f="$1" line="$2" tmp; tmp="$(mktemp)"
  awk -v L="  $line," 'NR==1{print; print L; next} {print}' "$f" >"$tmp" && mv "$tmp" "$f"
}

# ---------------------------------------------------------------- fixture repo
new_repo() { # → path
  local repo; repo="$(mktemp -d "$WORK/repo.XXXX")"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t \
      && mkdir -p tests && printf 'ok\n' >tests/t.sh \
      && git add -A && git commit -q -m init ) >/dev/null
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<JSON
{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "bash tests/t.sh", "testCommandSource": "configured", "created": "2026-05-30T00:00:00Z" }
JSON
  printf '# Context\n\nA fixture repo.\n' >"$repo/CONTEXT.md"
  printf '%s' "$repo"
}
write_prd() { cat >"$1" <<'EOF'
# Mission: Add a CSV export to the invoice list

**Type:** feature
**Goal:** A finance user can download the current invoice list as a CSV from the list page, so month-end reconciliation stops being copy-paste out of the table.
**Acceptance Criteria:**
- An "Export CSV" button sits above the invoice table
- Clicking it downloads `invoices-<YYYY-MM-DD>.csv`
- The CSV carries the same rows and columns the table currently shows, in the same order
- The export respects the active filters
**Out of Scope:**
- XLSX or PDF export
- Scheduled/emailed exports
**Constraints:**
- No new runtime dependencies
- Must stream for >10k rows rather than buffering
EOF
}
write_adr() { cat >"$1" <<'EOF'
# ADR: Stream the CSV from the existing query

**Context:** The invoice list is already paginated off a single query builder.
**Decision:** Reuse that builder with a cursor and stream rows to the response.
**Consequences:** No new deps; memory stays flat; the filter code path is shared.
**Alternatives considered:** Buffer the whole result set (rejected: 10k+ rows).
EOF
}
