#!/usr/bin/env bash
#
# Focused test for `attachments_extra_block` (skill source: skills/lcars-run/run.sh).
#
# S92: a mission's durable image attachments (staged under
# $MISSION_DIR/attachments/) must be threaded into the cold Stage workers as a
# block of ABSOLUTE paths so Research/Validate/Plan/Implement can READ them by
# path. This exercises the block in ISOLATION via run.sh's `attachments-block-test`
# hook (MISSION_DIR is taken from $LCARS_ATT_TEST_DIR — no locate_mission, no
# worker spawn, zero tokens):
#   1. dir with files  -> block carries the header + each ABSOLUTE path
#   2. dir absent/empty -> block is EMPTY (no-attachment missions byte-identical)
#
# Usage: bash tests/lcars-run-attachments.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

# S128 — the load-bearing precedence sentence, READ OUT OF THE DAEMON, which is
# its authority (see section 10). Every byte-exact assertion below pins against
# THIS value rather than a copy typed into the test, so a reword lands in one
# place and the suite still fails loudly for the shell lib until it follows.
PRECEDENCE="$(cd "$REPO_ROOT/web" 2>/dev/null && python3 -c 'import sys; sys.path.insert(0, "."); from lcars_serve.actions import _HANDOFF_PRECEDENCE as p; sys.stdout.write(p)' 2>/dev/null)"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

echo "attachments_extra_block"
[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

block_for() { # mission-dir
  LCARS_ATT_TEST_DIR="$1" bash "$SCRIPT" attachments-block-test 2>/dev/null
}

# 1. a mission dir WITH attachments → block carries the header + each abs path.
M1="$TMPROOT/m1"; mkdir -p "$M1/attachments"
printf 'AAA' >"$M1/attachments/attachment-01.png"
printf 'BBB' >"$M1/attachments/attachment-02.jpg"
out1="$(block_for "$M1")"
check "1. emits the Attached images header" \
  "printf '%s' \"\$out1\" | grep -q 'Attached images'"
check "1. emits the FIRST attachment's ABSOLUTE path" \
  "printf '%s' \"\$out1\" | grep -qF '$M1/attachments/attachment-01.png'"
check "1. emits the SECOND attachment's ABSOLUTE path" \
  "printf '%s' \"\$out1\" | grep -qF '$M1/attachments/attachment-02.jpg'"

# 2. a mission dir with NO attachments/ dir → empty block.
M2="$TMPROOT/m2"; mkdir -p "$M2"
out2="$(block_for "$M2")"
check "2. absent attachments dir ⇒ empty block" "[ -z \"\$out2\" ]"

# 3. an EMPTY attachments/ dir → empty block (no stray header).
M3="$TMPROOT/m3"; mkdir -p "$M3/attachments"
out3="$(block_for "$M3")"
check "3. empty attachments dir ⇒ empty block" "[ -z \"\$out3\" ]"

# ==========================================================================
# S127 — THE HEADING IS ADAPTIVE, AND AN IMAGE-ONLY MISSION IS UNTOUCHED.
#
# The holodeck hands a Mission a `mockup.html` + a `concept.md` on the SAME S92
# attachments road pasted screenshots travel, so the block that heads them
# `## Attached images` is now lying about half of what arrives. It adapts —
# but this is SHARED pipeline code, so the image-only case is asserted
# BYTE-IDENTICAL against the exact string it has always produced. If that
# assertion has to be "updated" to pass, the change was not additive.
# ==========================================================================
IMG_HEAD='## Attached images (the captain attached these; view/read them as part of your input)'

want1="$(printf '\n%s\n- %s\n- %s' "$IMG_HEAD" \
  "$M1/attachments/attachment-01.png" "$M1/attachments/attachment-02.jpg")"
check "4. image-only block is BYTE-IDENTICAL to the pre-S127 string" \
  "[ \"\$out1\" = \"\$want1\" ]"

# 5. a HOLODECK hand-off: one mockup + one concept doc, no images at all.
M4="$TMPROOT/m4"; mkdir -p "$M4/attachments"
printf '<!doctype html>' >"$M4/attachments/attachment-01.html"
printf '# concept'       >"$M4/attachments/attachment-02.md"
out4="$(block_for "$M4")"
check "5. non-image attachments do NOT get the images heading" \
  "! printf '%s' \"\$out4\" | grep -q 'Attached images'"
check "5. the heading names what actually arrived" \
  "printf '%s' \"\$out4\" | grep -q '## Attached files'"
check "5. it counts the mockup" \
  "printf '%s' \"\$out4\" | grep -qi 'mockup'"
check "5. it counts the document" \
  "printf '%s' \"\$out4\" | grep -qi 'document'"
check "5. it declares the mockup LOOK AND FLOW only" \
  "printf '%s' \"\$out4\" | grep -q 'LOOK AND FLOW'"
check "5. it says the mockup's internals are fake" \
  "printf '%s' \"\$out4\" | grep -qi 'internals are deliberately fake'"
check "5. it forbids editing/importing/shipping the mockup" \
  "printf '%s' \"\$out4\" | grep -qi 'do not import'"
check "5. it carries the precedence rule VERBATIM" \
  "printf '%s' \"\$out4\" | grep -qF \"\$PRECEDENCE\""
check "5. it still lists the mockup's ABSOLUTE path" \
  "printf '%s' \"\$out4\" | grep -qF '$M4/attachments/attachment-01.html'"
check "5. it still lists the concept doc's ABSOLUTE path" \
  "printf '%s' \"\$out4\" | grep -qF '$M4/attachments/attachment-02.md'"

# 6. MIXED — a pasted screenshot beside a holodeck mockup. The images must not
#    lose their own naming just because a mockup arrived with them.
M5="$TMPROOT/m5"; mkdir -p "$M5/attachments"
printf 'AAA'            >"$M5/attachments/attachment-01.png"
printf '<!doctype html>' >"$M5/attachments/attachment-02.html"
out5="$(block_for "$M5")"
check "6. mixed ⇒ the adaptive heading" \
  "printf '%s' \"\$out5\" | grep -q '## Attached files'"
check "6. mixed ⇒ the image is still named as an image" \
  "printf '%s' \"\$out5\" | grep -qi '1 image'"
check "6. mixed ⇒ both paths survive" \
  "printf '%s' \"\$out5\" | grep -qF '$M5/attachments/attachment-01.png' && printf '%s' \"\$out5\" | grep -qF '$M5/attachments/attachment-02.html'"

# 7. an attachment with NO mockup in it must not carry the mockup declaration —
#    the declaration is about a file that is actually there.
M6="$TMPROOT/m6"; mkdir -p "$M6/attachments"
printf '# notes' >"$M6/attachments/attachment-01.md"
out6="$(block_for "$M6")"
check "7. no mockup ⇒ no look-and-flow declaration" \
  "! printf '%s' \"\$out6\" | grep -q 'LOOK AND FLOW'"
check "7. no mockup ⇒ still the adaptive heading + the path" \
  "printf '%s' \"\$out6\" | grep -q '## Attached files' && printf '%s' \"\$out6\" | grep -qF '$M6/attachments/attachment-01.md'"

# ==========================================================================
# 8. FL-010 — THE ANTI-DRIFT GUARD. THE ONLY CHECK IN THIS FILE THAT WOULD HAVE
#    CAUGHT THE MISS.
#
# S127 made THIS block adaptive and every assertion above went green — while the
# SAME sentence stayed wrong in three other places (`lcars-file/file.sh` twice,
# `lcars-log/log.sh` once), each writing "## Attached images" over an HTML
# mockup into prd.md, the mission's own document and its GitHub issue body.
# Fixing a duplicated string in one of its homes and testing that home proves
# nothing about the others.
#
# So: the wording lives in ONE rule (lcars_attach_* in
# skills/lcars-init/lcars-common.sh) and the literal may appear in NO other
# skill source. A fifth copy fails here the moment it is written.
# ==========================================================================
COMMON_LIB="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
check "8. the shared rule exists in lcars-common.sh" \
  "[ -f '$COMMON_LIB' ] && grep -q '^lcars_attach_prd_section()' '$COMMON_LIB' && grep -q '^lcars_attach_heading()' '$COMMON_LIB'"

# Every skill source file that still spells the literal heading, minus the one
# home it is allowed to live in.
STRAY="$(cd "$REPO_ROOT" && grep -rl -- '## Attached images' skills/ 2>/dev/null \
          | grep -v '^skills/lcars-init/lcars-common.sh$')"
check "8. '## Attached images' is spelled in EXACTLY ONE skill source" \
  "[ -z \"\$STRAY\" ] || { echo \"stray copies: \$STRAY\"; false; }"

# The same guard for the honest heading and for the mockup declaration, so the
# non-image wording cannot be re-spelled per skill either.
STRAY_FILES="$(cd "$REPO_ROOT" && grep -rl -- '## Attached files' skills/ 2>/dev/null \
          | grep -v '^skills/lcars-init/lcars-common.sh$')"
check "8. '## Attached files' is spelled in EXACTLY ONE skill source" \
  "[ -z \"\$STRAY_FILES\" ] || { echo \"stray copies: \$STRAY_FILES\"; false; }"

STRAY_DECL="$(cd "$REPO_ROOT" && grep -rl -F -- "$PRECEDENCE" skills/ 2>/dev/null \
          | grep -v '^skills/lcars-init/lcars-common.sh$')"
check "8. the mockup declaration is spelled in EXACTLY ONE skill source" \
  "[ -z \"\$STRAY_DECL\" ] || { echo \"stray copies: \$STRAY_DECL\"; false; }"

# 9. …and the ONE rule agrees with itself across its two shapes: the cold-prompt
#    block (run.sh) and the prd.md section (file.sh / log.sh) must switch on the
#    same evidence. Drive the shared helper directly.
sec_for() { ( . "$COMMON_LIB"; lcars_attach_prd_section "$@" ); }
secIMG="$(sec_for 'attachments/attachment-01.png')"
check "9. helper: image-only section is BYTE-IDENTICAL to the pre-S128 string" \
  "[ \"\$secIMG\" = \"\$(printf '\n## Attached images\n\n- attachments/attachment-01.png\n')\" ]"
secMOCK="$(sec_for 'attachments/attachment-01.html' 'attachments/attachment-02.md')"
check "9. helper: a mockup is NOT called an image" \
  "! printf '%s' \"\$secMOCK\" | grep -q 'Attached images'"
check "9. helper: the section and the block agree on the noun" \
  "printf '%s' \"\$secMOCK\" | grep -q '## Attached files' && printf '%s' \"\$out5\" | grep -q '## Attached files'"
check "9. helper: the section carries the same declaration the block does" \
  "printf '%s' \"\$secMOCK\" | grep -qF \"\$PRECEDENCE\""

# ==========================================================================
# 10. S128 (FL-011 / A4a) — THE CROSS-LANGUAGE PIN.
#
# The precedence sentence has TWO legitimate homes and they are in different
# languages, so no constant can be shared:
#
#   • the DAEMON — `_HANDOFF_PRECEDENCE`, web/lcars_serve/actions.py. It is the
#     AUTHORITY ("spelled once, used everywhere"): the deck shows the block
#     before the captain sends and the daemon appends the same block to the
#     filed idea, so what he read and what the mission was told cannot differ.
#   • the SHELL LIB — `lcars_attach_mockup_note`, skills/lcars-init/
#     lcars-common.sh. `lcars file` and `lcars log` append it to prd.md for
#     every mockup-bearing mission, with no daemon in the process at all.
#
# Section 8's stray-copy scan CANNOT see a disagreement between them: each copy
# is in its own legitimate home and only the WORDING differs. That is exactly
# what happened during S128 — the daemon was reworded (the old "the brief wins"
# was read by a live cold worker as "the brief is EXHAUSTIVE", which is how the
# captain's theme got discarded on purpose, FL-011) and the shell lib was not,
# so ONE prd.md carried BOTH spellings and they disagreed.
#
# This check reads the daemon's literal out of the daemon itself and pins the
# shell lib's tail to it byte-for-byte. Reword either home alone and it goes
# red naming both.
# ==========================================================================
check "10. the daemon's _HANDOFF_PRECEDENCE is readable" "[ -n \"\$PRECEDENCE\" ]"
NOTE="$( . "$COMMON_LIB"; lcars_attach_mockup_note )"
check "10. the shell lib carries the DAEMON's sentence VERBATIM" \
  "printf '%s' \"\$NOTE\" | grep -qF \"\$PRECEDENCE\" || { printf 'daemon: %s\nshell : %s\n' \"\$PRECEDENCE\" \"\$(printf '%s' \"\$NOTE\" | tail -n 1)\"; false; }"
check "10. …as its LAST line — nothing older left below it" \
  "[ \"\$(printf '%s' \"\$NOTE\" | tail -n 1)\" = \"\$PRECEDENCE\" ]"
check "10. the shell lib spells the rule exactly ONCE" \
  "[ \"\$(grep -c 'Where the mockup and the brief disagree' '$COMMON_LIB')\" -eq 1 ]"
# …and the sentence the daemon publishes must still SAY both halves — an
# override that is not a completeness claim. A future reword that drops the
# TIE-BREAK half would keep both homes in perfect agreement about the wrong
# thing, and check 10 above would stay green.
check "10. the pinned sentence still denies the EXHAUSTIVE reading" \
  "printf '%s' \"\$PRECEDENCE\" | grep -qF 'OVERRIDES the mockup' && printf '%s' \"\$PRECEDENCE\" | grep -qF 'not a claim that the brief is exhaustive'"

# ==========================================================================
echo
printf 'attachments_extra_block: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
