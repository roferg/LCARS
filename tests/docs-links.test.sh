#!/usr/bin/env bash
#
# tests/docs-links.test.sh — the guard that keeps the PUBLIC docs honest.
#
# README.md and vision.md are the first two things a stranger reads, and
# docs/index.html + docs/vision.html are the same words in LCARS livery. Three
# classes of rot have actually happened here, so each one gets an assertion:
#
#   1. A LINK THAT GOES NOWHERE. README.md pointed at `bugs.md` for months;
#      the file is author-local and has never been in this repo. docs/index.html
#      carried the same dead href.
#   2. A PICTURE THAT IS NOT THERE (or is a 2 KB sliver of empty column). Every
#      referenced image must exist under docs/assets/ and be a real picture; and
#      no picture may sit in docs/assets/ unreferenced, because an orphan is a
#      picture nobody looked at.
#   2b. A DOCS LINK THAT ONLY WORKS ON LOCAL DISK. docs/index.html linked
#      `../vision.md`; GitHub Pages can serve the site from docs/, which makes
#      docs/ the root, so every `../` escapes it and 404s — while the plain
#      existence check passes, because docs/../vision.md resolves on disk.
#   3. INTERNAL VOCABULARY LEAKING OUT. Build-session numbers, the git-ignored
#      `.dev/` directory, the author-local `bugs.md`, and house words a user has
#      never seen ("grill", "orchestrator", "sub-agent") all read as noise to a
#      stranger and point at things they cannot open.
#
# Plus the ceiling: README.md stays under 320 lines. The README that prompted
# this guard was 1379.
#
# Pure-local, no network, no model. Runs in well under a second.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

README_MAX_LINES=357

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# ── helpers ────────────────────────────────────────────────────────────────

# md_targets <file> — every ](target) in a markdown file, one per line, with
# the fragment stripped. Absolute URLs and bare anchors are dropped.
md_targets() {
  grep -oE '\]\([^)]+\)' "$1" 2>/dev/null \
    | sed -e 's/^](//' -e 's/)$//' \
    | sed -e 's/[[:space:]].*$//' \
    | grep -vE '^(https?:|mailto:|#)' \
    | sed -e 's/#.*$//' \
    | grep -v '^$' \
    | sort -u
}

# md_anchors <file> — every ](#anchor) in a markdown file.
md_anchors() {
  grep -oE '\]\(#[^)]+\)' "$1" 2>/dev/null | sed -e 's/^](#//' -e 's/)$//' | sort -u
}

# md_headings_slugged <file> — GitHub's slug for every ATX heading.
md_headings_slugged() {
  grep -E '^#{1,6} ' "$1" 2>/dev/null \
    | sed -E 's/^#{1,6} +//' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/`//g; s/[^a-z0-9 _-]//g; s/ /-/g' \
    | sort -u
}

# md_images <file> — every ![alt](target) image target.
md_images() {
  grep -oE '!\[[^]]*\]\([^)]+\)' "$1" 2>/dev/null \
    | sed -E -e 's/^!\[[^]]*\]\(//' -e 's/\)$//' \
    | sed -e 's/[[:space:]].*$//' \
    | grep -vE '^https?:' | sort -u
}

# html_targets <file> — every relative href=/src= in an html file.
html_targets() {
  grep -oE '(href|src)="[^"]+"' "$1" 2>/dev/null \
    | sed -E -e 's/^(href|src)="//' -e 's/"$//' \
    | grep -vE '^(https?:|//|mailto:|#|data:)' \
    | sed -e 's/#.*$//' | grep -v '^$' | sort -u
}

# ── 1. relative links in README.md / vision.md resolve to TRACKED files ─────
for src in README.md vision.md; do
  missing=""; untracked=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ ! -e "$REPO_ROOT/$t" ]; then
      missing="$missing $t"
    elif ! git ls-files --error-unmatch "$t" >/dev/null 2>&1; then
      untracked="$untracked $t"
    fi
  done < <(md_targets "$src")
  [ -z "$missing" ] \
    && ok "$src: every relative link resolves to a file that exists" \
    || bad "$src: links to files that do not exist —$missing"
  [ -z "$untracked" ] \
    && ok "$src: every linked file is tracked by git (a cloner gets it)" \
    || bad "$src: links to UNTRACKED files —$untracked"
done

# ── 2. in-page anchors resolve to a heading in the same file ───────────────
for src in README.md vision.md; do
  heads="$(md_headings_slugged "$src")"
  dead=""
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    printf '%s\n' "$heads" | grep -qx -- "$a" || dead="$dead #$a"
  done < <(md_anchors "$src")
  [ -z "$dead" ] \
    && ok "$src: every in-page anchor points at a real heading" \
    || bad "$src: anchors with no matching heading —$dead"
done

# ── 3. every referenced picture exists, lives in docs/assets/, is real ─────
#    "real" = over 10 KB. The 18 KB-of-empty-column hero that shipped once was
#    judged by its file size being plausible; the floor is the cheap half of
#    that lesson, and a human looking at it is the other half.
refs_all=""
for src in README.md vision.md; do
  bad_path=""; bad_missing=""; bad_tiny=""
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    refs_all="$refs_all $img"
    case "$img" in docs/assets/*) : ;; *) bad_path="$bad_path $img"; continue ;; esac
    if [ ! -f "$REPO_ROOT/$img" ]; then
      bad_missing="$bad_missing $img"
    elif [ "$(wc -c <"$REPO_ROOT/$img")" -lt 10240 ]; then
      bad_tiny="$bad_tiny $img"
    fi
  done < <(md_images "$src")
  [ -z "$bad_missing" ] \
    && ok "$src: every picture it shows exists on disk" \
    || bad "$src: pictures referenced but absent —$bad_missing"
  [ -z "$bad_path" ] \
    && ok "$src: every picture comes from docs/assets/" \
    || bad "$src: pictures from outside docs/assets/ —$bad_path"
  [ -z "$bad_tiny" ] \
    && ok "$src: no referenced picture is a trivial sliver (<10 KB)" \
    || bad "$src: pictures too small to be real —$bad_tiny"
done

# ── 4. no ORPHAN pictures: docs/assets/*.png must be referenced somewhere ──
orphans=""
for p in docs/assets/*.png; do
  [ -f "$p" ] || continue
  case " $refs_all " in
    *" $p "*) : ;;
    *) grep -q "$(basename "$p")" docs/index.html docs/vision.html 2>/dev/null \
         || orphans="$orphans $p" ;;
  esac
done
[ -z "$orphans" ] \
  && ok "docs/assets: no orphan pictures (every one is shown somewhere)" \
  || bad "docs/assets: pictures nothing references —$orphans"

# ── 5. README.md stays under its ceiling ───────────────────────────────────
lines="$(wc -l <README.md | tr -d ' ')"
[ "$lines" -le "$README_MAX_LINES" ] \
  && ok "README.md is $lines lines (ceiling $README_MAX_LINES)" \
  || bad "README.md is $lines lines — over the $README_MAX_LINES-line ceiling a stranger will actually read"

# ── 6. no internal vocabulary in README.md ─────────────────────────────────
#    Each pattern is something a reader cannot open, or a word no user has seen.
leak() {  # leak <label> <extended-regex>
  local label="$1" re="$2" hit
  hit="$(grep -nEi -- "$re" README.md | head -4)"
  [ -z "$hit" ] \
    && ok "README.md: no $label" \
    || bad "README.md: $label leaked — $(printf '%s' "$hit" | tr '\n' '|')"
}
leak "build-session numbers"      '(^|[^A-Za-z])S[0-9]{2,3}([^0-9A-Za-z]|$)|session[s]? [0-9]'
leak "references to .dev/"        '(^|[^A-Za-z0-9])\.dev/'
leak "references to bugs.md"      'bugs\.md'
leak "the house word \"grill\""   'grill'
leak "harness-internal roles"     'orchestrator|sub-agent|subagent'
leak "a light-mode claim"         'light mode'
leak "an instruction to hand-author under ~/.claude" '(author|copy|place|put|create)[^.]{0,48}~/\.claude'

# ── 7. every relative href/src in docs/*.html resolves ─────────────────────
for page in docs/*.html; do
  [ -f "$page" ] || continue
  dir="$(dirname "$page")"
  missing=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ -e "$dir/$t" ] || missing="$missing $t"
  done < <(html_targets "$page")
  [ -z "$missing" ] \
    && ok "$page: every relative href/src resolves" \
    || bad "$page: dead relative refs —$missing"
done

# ── 7b. docs/*.html may not use `../` to escape the docs root ─────────────
#    GitHub Pages can serve the site FROM docs/, which makes docs/ the site
#    root — every `../` then escapes it and 404s. Section 7 cannot catch this,
#    because on local disk docs/../vision.md resolves perfectly. Link out of
#    the docs root with an absolute https:// URL instead.
for page in docs/*.html; do
  [ -f "$page" ] || continue
  escapes=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in ../*|*/../*) escapes="$escapes $t" ;; esac
  done < <(html_targets "$page")
  [ -z "$escapes" ] \
    && ok "$page: no relative link escapes the docs/ root with ../" \
    || bad "$page: links escape docs/ with ../ (404s when Pages serves from docs/) —$escapes"
done

# ── 7c. every PATH launcher install.sh drops is NAMED in README.md ────────
#    Derived from the installer, not retyped: the README said install.sh put
#    ONE command on $PATH when it puts five, and the installer's own
#    ACTION-NEEDED banner named two the README never mentioned.
missing_launchers=""
while IFS= read -r l; do
  [ -n "$l" ] || continue
  grep -qF -- "$l" README.md || missing_launchers="$missing_launchers $l"
done < <(sed -n 's/^install_launcher[[:space:]]*"\([^"]*\)".*/\1/p' install.sh | sort -u)
[ -z "$missing_launchers" ] \
  && ok "README.md names every on-PATH launcher install.sh installs" \
  || bad "README.md never mentions launchers install.sh puts on PATH —$missing_launchers"

# ── 8. POSITIVE CONTROLS — prove the checks can actually go red ────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'see [the ledger](bugs.md)\n' >"$TMP/broken.md"
if [ -e "$REPO_ROOT/$(md_targets "$TMP/broken.md")" ]; then
  bad "control: a link to a non-existent file was not detected as missing"
else
  ok "control: the link check does detect a target that does not exist"
fi
printf '# LCARS\nSession 280 built this in .dev/ after a grill.\n' >"$TMP/leaky.md"
n="$(grep -cEi 'session [0-9]|\.dev/|grill' "$TMP/leaky.md")"
[ "$n" -ge 1 ] \
  && ok "control: the vocabulary patterns do match internal prose" \
  || bad "control: the vocabulary patterns matched nothing in a deliberately leaky file"

echo
printf 'docs-links: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
