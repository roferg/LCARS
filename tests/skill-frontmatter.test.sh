#!/usr/bin/env bash
#
# tests/skill-frontmatter.test.sh — the gate that keeps every SKILL.md
# loadable by BOTH CLIs.
#
# WHAT WENT WRONG (measured against the real `copilot` binary, 2026-10-11).
# `copilot skill list` loaded ELEVEN of LCARS's NINETEEN skills and printed:
#
#   ✖ The following skills failed to load:
#     • skills/lcars-adopt/SKILL.md:      … at line 2 column 306
#     • skills/lcars-approve/SKILL.md:    … at line 2 column 312
#     • skills/lcars-buddy/SKILL.md:      … at line 2 column 244
#     • skills/lcars-pause/SKILL.md:      … at line 2 column 167
#     • skills/lcars-run/SKILL.md:        description must be at most 1024 chars
#     • skills/lcars-update/SKILL.md:     … at line 2 column 636
#     • skills/lcars-viewscreen/SKILL.md: … at line 2 column 410
#     • skills/lcars-xo/SKILL.md:         … at line 2 column 923
#
# Two independent causes, BOTH invisible to Claude Code — which is exactly
# why nothing caught them for months:
#
#   1. Every SKILL.md carried a one-line UNQUOTED `description:` whose prose
#      contained `": "`. A strict YAML reader sees a nested mapping key
#      inside the scalar and refuses the whole document. Claude Code's
#      parser tolerates it.
#   2. Copilot caps the description at 1024 characters. Six were over.
#
# WHY A SUITE AND NOT A ONE-OFF FIX. The fix is 19 files of prose, and prose
# grows. `lcars-launch` sat at 1005 characters — nineteen away from failing —
# and was not even on the measured failure list. The next sentence somebody
# adds to it, or the next colon, silently un-ships a skill in one CLI while
# the other stays green. So the shape is pinned here instead:
#
#   * a `>-` block scalar (or a double-quoted one), never a plain one-liner,
#     so prose can never be re-read as structure;
#   * a FOLDED length of at most 1024, because a `>-` fold joins its lines
#     with single spaces and the length that matters is the one the CLI
#     computes, not the one the file looks like;
#   * `name:` equal to the directory name, so the skill a user types is the
#     one they read.
#
# THE CONTROL. A checker that has only ever seen the clean tree cannot
# detect its own breakage. Section 1 therefore drives the checker RED once
# per rule on THROWAWAY fixtures — a plain one-liner, a 1025-character fold,
# a wrong `name:` — and GREEN on the legitimate shapes, so "everything
# passes" cannot pass for a working gate. Section 2 then runs it on the real
# 19. Section 4 goes further and asks the REAL `copilot` binary.
#
#   bash tests/skill-frontmatter.test.sh

set -uo pipefail

# qgrep: drain stdin FULLY before grepping. A piped `grep -q` short-circuits
# on its first match and closes the pipe; a still-writing upstream producer
# then takes SIGPIPE and exits non-zero, and under `set -o pipefail` that
# flips a genuine match into a phantom assertion failure. Draining first
# removes the race. It reads stdin ONLY when no FILE operand was given —
# draining with a FILE passed would read INHERITED stdin, which blocks
# forever on a terminal and silently returns empty when stdin is closed.
qgrep() {
  local _qg_a _qg_in _qg_n=0 _qg_opt=1
  for _qg_a in "$@"; do
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" = "--" ]; then _qg_opt=0; continue; fi
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" != "${_qg_a#-}" ] && [ "$_qg_a" != "-" ]; then continue; fi
    _qg_n=$((_qg_n + 1))
  done
  if [ "$_qg_n" -ge 2 ]; then grep "$@"; return; fi
  _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/lib/skill_frontmatter.py"
GEN="$REPO_ROOT/gen-copilot-plugin.sh"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"

pass=0
fail=0
skip=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
skp()  { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

[ -f "$CHECK" ] || { echo "missing checker: $CHECK" >&2; exit 1; }

# mkskill <dir> <name-line> <description-block...>  — build a fixture skill.
# Everything after the name line is written verbatim as the rest of the
# frontmatter, so a fixture can be deliberately malformed.
mkskill() {
  local dir="$1"; shift
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf '%s\n' "$@"
    printf -- '---\n\nBody.\n'
  } >"$dir/SKILL.md"
}

# wrap_block <text> — print <text> as indented `>-` continuation lines,
# wrapped on single spaces so the fold reproduces it byte for byte.
wrap_block() {
  python3 - "$1" <<'PY'
import sys, textwrap
for line in textwrap.wrap(sys.argv[1], width=70, break_long_words=False,
                          break_on_hyphens=False):
    print("  " + line)
PY
}

echo "== section 1: the checker itself, driven both ways on throwaway fixtures =="

# --- 1a: the legitimate shape passes -------------------------------------
d="$TMPROOT/good"
mkdir -p "$d"
{
  printf -- '---\nname: good\ndescription: >-\n'
  wrap_block "A perfectly ordinary skill: it does a thing, and it says so. Use when the user asks for it."
  printf -- '---\n\nBody.\n'
} >"$d/SKILL.md"
out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
check "1a. a \`>-\` block scalar whose prose contains \": \" PASSES (rc=0)" "[ $rc -eq 0 ]"
check "1a. and is reported OK" "printf '%s' \"\$out\" | qgrep -q '^OK   '"

# --- 1b: a plain one-liner containing ": " is REJECTED -------------------
d="$TMPROOT/colonspace"
mkskill "$d" 'name: colonspace' \
  'description: Your ride-along buddy — extra detail the normal surfaces do not show: where the source sits. Use when the user asks.'
out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
check "1b. a plain one-line description containing \": \" is REJECTED (rc=1)" "[ $rc -eq 1 ]"
check "1b. the refusal names rule R4" "printf '%s' \"\$out\" | qgrep -q 'FAIL .*: R4 '"
check "1b. and says why (the nested-mapping trap)" "printf '%s' \"\$out\" | qgrep -q 'nested mapping'"

# --- 1c: a plain one-liner with NO ": " is ALSO rejected (the policy) ----
d="$TMPROOT/plainclean"
mkskill "$d" 'name: plainclean' \
  'description: A one-line description with no colon-space at all. Use when asked.'
out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
check "1c. a plain one-liner is rejected even WITHOUT \": \" — one colon from breaking" "[ $rc -eq 1 ]"
check "1c. as R4" "printf '%s' \"\$out\" | qgrep -q 'FAIL .*: R4 '"

# --- 1d/1e: the 1024 boundary, measured FOLDED ---------------------------
# Build a description of an exact character length out of real words, so the
# fold rejoins it to precisely that many characters.
exact_desc() { # <n>
  python3 - "$1" <<'PY'
import sys
n = int(sys.argv[1])
word = "alpha"
s = []
total = 0
while total < n:
    remaining = n - total
    if remaining >= len(word) + 1 and total:
        s.append(word); total += len(word) + 1
    elif not total:
        s.append(word); total += len(word)
    else:
        s.append("x" * (remaining - 1)); total += remaining
print(" ".join(s), end="")
PY
}

for n in 1024 1025; do
  d="$TMPROOT/len$n"
  mkdir -p "$d"
  desc="$(exact_desc "$n")"
  actual="${#desc}"
  {
    printf -- '---\nname: len%s\ndescription: >-\n' "$n"
    wrap_block "$desc"
    printf -- '---\n\nBody.\n'
  } >"$d/SKILL.md"
  # the generator must have produced exactly n characters, or the boundary
  # test is testing the wrong number
  check "1d/e. fixture len$n really is $n characters (got $actual)" "[ $actual -eq $n ]"
  # and the SOURCE is wider than the value, proving FOLDED length is what is
  # measured and not raw bytes
  src="$(wc -c <"$d/SKILL.md" | tr -d ' ')"
  check "1d/e. len$n's SKILL.md is $src bytes — wider than the value, so the cap is folded-length" "[ $src -gt $n ]"
  out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
  if [ "$n" -eq 1024 ]; then
    check "1d. a folded description of exactly 1024 characters is ACCEPTED" "[ $rc -eq 0 ]"
  else
    check "1e. a folded description of 1025 characters is REJECTED" "[ $rc -eq 1 ]"
    check "1e. as R5, naming the measured length" "printf '%s' \"\$out\" | qgrep -q 'R5 folded description is 1025 characters'"
  fi
done

# --- 1f: name must equal the directory name -----------------------------
d="$TMPROOT/lcars-whatever"
mkdir -p "$d"
{
  printf -- '---\nname: lcars-something-else\ndescription: >-\n'
  wrap_block "A skill whose name does not match its directory. Use when asked."
  printf -- '---\n\nBody.\n'
} >"$d/SKILL.md"
out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
check "1f. \`name:\` not equal to the directory name is REJECTED" "[ $rc -eq 1 ]"
check "1f. as R3, naming both" "printf '%s' \"\$out\" | qgrep -q \"R3 name 'lcars-something-else' != directory name 'lcars-whatever'\""

# --- 1g: a double-quoted description is accepted ------------------------
d="$TMPROOT/dquoted"
mkskill "$d" 'name: dquoted' \
  'description: "A quoted description: the colon is safe inside quotes. Use when asked."'
out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
check "1g. a double-quoted description is ACCEPTED" "[ $rc -eq 0 ]"

# --- 1h: another top-level key with an unquoted ": " --------------------
d="$TMPROOT/otherkey"
mkdir -p "$d"
{
  printf -- '---\nname: otherkey\nlicense: MIT: see LICENSE\ndescription: >-\n'
  wrap_block "A fine description. Use when asked."
  printf -- '---\n\nBody.\n'
} >"$d/SKILL.md"
out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
check "1h. a NON-description top-level key with an unquoted \": \" is REJECTED" "[ $rc -eq 1 ]"
check "1h. as R6, naming the key" "printf '%s' \"\$out\" | qgrep -q 'R6 .license:. is unquoted'"
# ...and the same key, quoted, is fine — so R6 is a quoting rule, not a ban
d="$TMPROOT/otherkeyok"
mkdir -p "$d"
{
  printf -- '---\nname: otherkeyok\nlicense: "MIT: see LICENSE"\ndescription: >-\n'
  wrap_block "A fine description. Use when asked."
  printf -- '---\n\nBody.\n'
} >"$d/SKILL.md"
check "1h. the same key QUOTED is accepted (R6 is a quoting rule, not a ban)" \
  "python3 \"$CHECK\" \"$TMPROOT/otherkeyok\" >/dev/null 2>&1"

# --- 1i: no frontmatter at all ------------------------------------------
d="$TMPROOT/nofm"
mkdir -p "$d"
printf '# Just a heading\n\nNo frontmatter here.\n' >"$d/SKILL.md"
out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
check "1i. a SKILL.md with no frontmatter is REJECTED as R1" \
  "[ $rc -eq 1 ] && printf '%s' \"\$out\" | qgrep -q 'R1 '"

# --- 1j: an unclosed frontmatter ----------------------------------------
d="$TMPROOT/unclosed"
mkdir -p "$d"
printf -- '---\nname: unclosed\ndescription: >-\n  Something. Use when asked.\n' >"$d/SKILL.md"
out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
check "1j. an unclosed frontmatter is REJECTED as R1" \
  "[ $rc -eq 1 ] && printf '%s' \"\$out\" | qgrep -q 'never closed'"

# --- 1k: a missing description -----------------------------------------
d="$TMPROOT/nodesc"
mkdir -p "$d"
printf -- '---\nname: nodesc\n---\n\nBody.\n' >"$d/SKILL.md"
out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
check "1k. a missing \`description:\` is REJECTED as R4" \
  "[ $rc -eq 1 ] && printf '%s' \"\$out\" | qgrep -q 'R4 no .description:. key'"

echo
echo "== section 2: every real skills/*/SKILL.md =="

# bash 3.2 (the macOS system bash this repo is tested on) has no `mapfile`.
SKILL_DIRS=()
while IFS= read -r _d; do
  [ -n "$_d" ] && SKILL_DIRS+=("$_d")
done <<EOF
$(find "$REPO_ROOT/skills" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
EOF
n_skills="${#SKILL_DIRS[@]}"
check "2. there are 19 skill directories (found $n_skills)" "[ $n_skills -eq 19 ]"

out="$(python3 "$CHECK" "${SKILL_DIRS[@]}" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "2. all $n_skills skills pass the strict frontmatter checker"
else
  bad "2. the strict frontmatter checker refused at least one skill"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# Per-skill, so a failure names the skill rather than the batch.
for d in "${SKILL_DIRS[@]}"; do
  name="$(basename "$d")"
  if python3 "$CHECK" "$d" >/dev/null 2>&1; then
    ok "2. $name parses strictly"
  else
    bad "2. $name does NOT parse strictly"
  fi
done

# The two properties the CLIs actually enforce, asserted directly off the
# file so this does not depend only on the checker agreeing with itself.
for d in "${SKILL_DIRS[@]}"; do
  name="$(basename "$d")"
  hdr="$(sed -n '1,/^---$/p' "$d/SKILL.md" | grep -m1 '^description:' || true)"
  case "$hdr" in
    'description: >-'|'description: >'|'description: |'|'description: |-')
      ok "2. $name declares a block-scalar description (${hdr#description: })" ;;
    'description: "'*'"')
      ok "2. $name declares a double-quoted description" ;;
    *)
      bad "2. $name's description header is neither a block scalar nor double-quoted: ${hdr:0:40}" ;;
  esac
done

echo
echo "-- section 2b: the folded lengths, and the trigger phrase --"
lens="$(python3 - "$CHECK" "${SKILL_DIRS[@]}" <<'PY'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("sfm", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
over = 0
for d in sys.argv[2:]:
    try:
        info = m.describe(d)
    except Exception as exc:
        print("ERR %s %s" % (os.path.basename(d), exc)); over += 1; continue
    flag = "OVER" if info["length"] > m.MAX_DESCRIPTION else "ok"
    trig = "trigger" if "Use when" in info["description"] else "NO-TRIGGER"
    print("%s %s %d %s" % (flag, os.path.basename(d), info["length"], trig))
PY
)"
printf '%s\n' "$lens" | sed 's/^/        /'
check "2b. no skill's folded description exceeds 1024 characters" \
  "! printf '%s\n' \"\$lens\" | qgrep -q '^OVER '"
check "2b. no skill failed to parse while measuring" \
  "! printf '%s\n' \"\$lens\" | qgrep -q '^ERR '"
check "2b. every skill keeps a \"Use when\" trigger phrase in its description" \
  "! printf '%s\n' \"\$lens\" | qgrep -q 'NO-TRIGGER'"

echo
echo "== section 3: .claude-plugin/plugin.json is untouched by this change =="
# gen-copilot-plugin.sh reads ONLY the directory list, so rewriting 19
# descriptions must not move a byte of the manifest. Regenerating into a
# temp file and comparing byte for byte proves both halves at once: the
# tracked manifest is what the generator produces, and the generator does
# not read descriptions.
check "3. the tracked manifest exists" "[ -f \"$MANIFEST\" ]"
LCARS_PLUGIN_OUT="$TMPROOT/plugin.json" bash "$GEN" >/dev/null 2>&1
check "3. regenerating the manifest produces a byte-identical file" \
  "cmp -s \"$MANIFEST\" \"$TMPROOT/plugin.json\""
check "3. and it lists all 19 skills" \
  "[ \"\$(qgrep -c '\"./skills/' \"$MANIFEST\")\" -eq 19 ]"

echo
echo "== section 4: the LIVE probe — the real copilot binary =="
# Guarded, and it SKIPS loudly rather than passing quietly. Two independent
# reasons it may not run: no `copilot` on PATH, or a `copilot` too old to
# take `--plugin-dir`.
#
# WHY `--plugin-dir` AND NOT THE INSTALLED PLUGIN. The live registration at
# ~/.copilot/installed-plugins/_direct/lcars points at whichever checkout
# last ran ./install.sh — usually NOT this one. Asserting against it would
# grade someone else's tree, and re-pointing it from a test would hijack the
# captain's working Copilot setup. `copilot --plugin-dir <repo> skill list`
# loads THIS checkout, read-only, with no model turn and without touching
# that symlink. The failure lines are therefore attributed by path, so the
# other registered plugin's problems are not this suite's verdict.
#
# AND WHY THE FAILURE DETECTOR HAS ITS OWN CONTROL. The first spelling of
# this probe filtered failure lines by the absolute "$REPO_ROOT/" prefix —
# and PASSED on the known-broken tree, because copilot prints a path
# RELATIVE to the session working directory when that directory is the
# plugin dir ("skills/lcars-adopt/SKILL.md"), and absolute otherwise. A
# detector that cannot see the failure it exists to catch is worse than no
# detector, so 4a plants a deliberately broken skill in a throwaway plugin
# dir and requires the SAME extractor to report it before 4b's "no failures"
# is allowed to mean anything.
COPILOT_BIN="${LCARS_COPILOT_BIN:-copilot}"

# failing_skills <listing-file> <plugin-root> — print the name of each skill
# the listing says failed to load, counting only skills under <plugin-root>.
# A bullet's path is relative to the directory copilot ran in, which the
# caller sets to <plugin-root>, so both spellings resolve correctly.
failing_skills() {
  python3 - "$1" "$2" <<'PY'
import os, re, sys
root = os.path.realpath(sys.argv[2])
seen = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.match(r"^\s*[•*-]\s+(\S.*?SKILL\.md):", line)
    if not m:
        continue
    p = m.group(1)
    full = os.path.realpath(p if os.path.isabs(p) else os.path.join(root, p))
    if not full.startswith(root + os.sep):
        continue
    name = os.path.basename(os.path.dirname(full))
    if name not in seen:
        seen.append(name)
for n in seen:
    print(n)
PY
}

if ! command -v "$COPILOT_BIN" >/dev/null 2>&1; then
  skp "4. SKIPPED: no \`$COPILOT_BIN\` on PATH — the live load is unproven here (not a pass)"
elif ! "$COPILOT_BIN" --help 2>&1 | qgrep -q -- '--plugin-dir'; then
  skp "4. SKIPPED: this \`$COPILOT_BIN\` has no --plugin-dir, so this checkout cannot be loaded without re-pointing the captain's live plugin (not a pass)"
else
  # --- 4a: the CONTROL. A broken skill in a throwaway plugin must be seen.
  BAD="$TMPROOT/badplugin"
  mkdir -p "$BAD/.claude-plugin" "$BAD/skills/zz-bad-fixture"
  printf '{\n  "name": "zzbad",\n  "skills": ["./skills/zz-bad-fixture"]\n}\n' \
    >"$BAD/.claude-plugin/plugin.json"
  mkskill "$BAD/skills/zz-bad-fixture" 'name: zz-bad-fixture' \
    'description: A fixture that must not load: this colon-space is the whole point. Use when never.'
  ( cd "$BAD" && "$COPILOT_BIN" --plugin-dir "$BAD" skill list ) \
    >"$TMPROOT/bad-list.txt" 2>&1
  ctl="$(failing_skills "$TMPROOT/bad-list.txt" "$BAD")"
  probe_trustworthy=0
  if printf '%s\n' "$ctl" | qgrep -qx 'zz-bad-fixture'; then
    ok "4a. CONTROL: the live failure detector DOES see a deliberately broken skill"
    probe_trustworthy=1
  else
    bad "4a. CONTROL: the live failure detector did NOT see a deliberately broken skill — 4b cannot be trusted"
    sed -n '/failed to load/,$p' "$TMPROOT/bad-list.txt" | sed 's/^/        /' | head -10
  fi

  # --- 4b/4c: the real tree.
  live_txt="$TMPROOT/skill-list.txt"
  live_json="$TMPROOT/skill-list.json"
  ( cd "$REPO_ROOT" && "$COPILOT_BIN" --plugin-dir "$REPO_ROOT" skill list ) \
    >"$live_txt" 2>&1
  ( cd "$REPO_ROOT" && "$COPILOT_BIN" --plugin-dir "$REPO_ROOT" skill list --json ) \
    >"$live_json" 2>/dev/null
  if [ ! -s "$live_txt" ]; then
    skp "4b. SKIPPED: \`$COPILOT_BIN skill list\` produced no output (not a pass)"
  elif [ "$probe_trustworthy" -ne 1 ]; then
    skp "4b. SKIPPED: the detector failed its own control, so its silence proves nothing (not a pass)"
  else
    mine="$(failing_skills "$live_txt" "$REPO_ROOT")"
    if [ -z "$mine" ]; then
      ok "4b. LIVE: \`copilot skill list\` reports NO load failure under this checkout"
    else
      bad "4b. LIVE: \`copilot skill list\` still refuses: $(printf '%s' "$mine" | tr '\n' ' ')"
      sed -n '/failed to load/,$p' "$live_txt" | sed 's/^/        /'
    fi
  fi

  found="$(python3 - "$live_json" "$REPO_ROOT" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception as exc:
    print("PARSE-ERROR %s" % exc); raise SystemExit(0)
root = sys.argv[2].rstrip("/") + "/skills/"
for r in rows:
    p = (r.get("path") or "")
    if p.startswith(root):
        print(p[len(root):].strip("/"))
PY
)"
  if printf '%s' "$found" | qgrep -q 'PARSE-ERROR'; then
    skp "4c. SKIPPED: could not read \`skill list --json\` ($found) (not a pass)"
  else
    missing=""
    for d in "${SKILL_DIRS[@]}"; do
      name="$(basename "$d")"
      printf '%s\n' "$found" | qgrep -qx "$name" || missing="$missing $name"
    done
    n_found="$(printf '%s\n' "$found" | grep -c . || true)"
    if [ -z "$missing" ]; then
      ok "4c. LIVE: all $n_skills skills of this checkout appear in \`copilot skill list\` ($n_found loaded)"
    else
      bad "4c. LIVE: copilot did not load:$missing"
    fi
  fi
fi

echo
printf 'skill-frontmatter: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
