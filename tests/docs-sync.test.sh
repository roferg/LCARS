#!/usr/bin/env bash
# Fast, SCOPED, pure-local test for the docs-sync guard.
#
# docs/index.html and docs/vision.html are hand-authored LCARS-themed HTML
# mirrors of the source markdown. There is NO build step, so nothing but this
# guard notices when a source drifts from its mirror. Each html mirror carries
# one breadcrumb comment per named source, placed right after <!DOCTYPE html>:
#
#     <!-- lcars-docs-src: vision.md sha256:<64-hex> -->
#
# The guard recomputes `shasum -a 256` of each named source and compares it to
# the breadcrumb hash. A mismatch means the source changed but the page wasn't
# re-mirrored (or its breadcrumb wasn't refreshed); a missing breadcrumb / a
# missing source is likewise a failure.
#
# This suite exercises IN-SYNC / DRIFT / STRIPPED against temp copies (so the
# real tracked files are never mutated), then runs the check once against the
# REAL repo files — that real-repo PASS is the guard that fires in run.sh on
# actual drift.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# sha256_of <file> -> echoes the bare 64-hex digest (no filename)
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# check_breadcrumbs <base_dir> <html_relpath>
#   Parses every `lcars-docs-src: <src> sha256:<hash>` breadcrumb out of the
#   html file, recomputes the hash of <src> (resolved relative to base_dir),
#   and compares. Emits actionable errors to stdout. Returns 0 iff all match
#   and at least one breadcrumb was present.
check_breadcrumbs() {
  local base="$1" html_rel="$2" html="$1/$2"
  local found=0 fail=0 line src want got

  if [ ! -f "$html" ]; then
    echo "docs-sync: $html_rel is missing"
    return 1
  fi

  while IFS= read -r line; do
    # line looks like:  <!-- lcars-docs-src: vision.md sha256:abc... -->
    src="$(printf '%s\n' "$line" | sed -n 's/.*lcars-docs-src:[[:space:]]*\([^[:space:]]*\)[[:space:]]*sha256:.*/\1/p')"
    want="$(printf '%s\n' "$line" | sed -n 's/.*sha256:\([0-9a-f]*\).*/\1/p')"
    [ -z "$src" ] && continue
    found=$((found+1))
    if [ ! -f "$base/$src" ]; then
      echo "docs-sync: $html_rel names source $src but $src does not exist"
      fail=1
      continue
    fi
    got="$(sha256_of "$base/$src")"
    if [ "$got" != "$want" ]; then
      echo "docs-sync: $src changed since $html_rel was mirrored — update the page, then refresh its breadcrumb hash (expected sha256:$got, breadcrumb has sha256:$want)"
      fail=1
    fi
  done < <(grep 'lcars-docs-src:' "$html" || true)

  if [ "$found" -eq 0 ]; then
    echo "docs-sync: $html_rel has no lcars-docs-src breadcrumb"
    return 1
  fi
  return "$fail"
}

# --- case 0: REAL repo files are in sync (the guard that fires in run.sh) ----
OUT="$(check_breadcrumbs "$REPO_ROOT" "docs/vision.html" 2>&1)"; RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "real docs/vision.html in sync with vision.md" \
  || bad "real docs/vision.html in sync with vision.md ($OUT)"

OUT="$(check_breadcrumbs "$REPO_ROOT" "docs/index.html" 2>&1)"; RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "real docs/index.html in sync with README.md + vision.md" \
  || bad "real docs/index.html in sync with README.md + vision.md ($OUT)"

# --- Build a temp layout mirroring the real one for mutation cases ----------
mkdir -p "$TMPROOT/docs"
cp "$REPO_ROOT/README.md"        "$TMPROOT/README.md"
cp "$REPO_ROOT/vision.md"        "$TMPROOT/vision.md"
cp "$REPO_ROOT/docs/index.html"  "$TMPROOT/docs/index.html"
cp "$REPO_ROOT/docs/vision.html" "$TMPROOT/docs/vision.html"

# Re-stamp the temp html breadcrumbs so each hash matches the copied source in
# $TMPROOT. This makes the IN-SYNC case a true positive control independent of
# whether the real working tree is currently drifted — case 1 is green by
# construction, while the DRIFT case (which mutates a temp source AFTER this)
# still goes red.
for html in "$TMPROOT/docs/vision.html" "$TMPROOT/docs/index.html"; do
  while IFS= read -r line; do
    src="$(printf '%s\n' "$line" | sed -n 's/.*lcars-docs-src:[[:space:]]*\([^[:space:]]*\)[[:space:]]*sha256:.*/\1/p')"
    [ -z "$src" ] && continue
    [ -f "$TMPROOT/$src" ] || continue
    new="$(sha256_of "$TMPROOT/$src")"
    # Rewrite only the hash on this src's breadcrumb line, leaving format intact.
    sed -i.bak "s|\(lcars-docs-src:[[:space:]]*$src[[:space:]]*sha256:\)[0-9a-f]*|\1$new|" "$html"
  done < <(grep 'lcars-docs-src:' "$html" || true)
  rm -f "$html.bak"
done

# --- case 1: IN-SYNC temp copy passes ---------------------------------------
OUT="$(check_breadcrumbs "$TMPROOT" "docs/vision.html" 2>&1)"; RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "temp copy in sync passes" \
  || bad "temp copy in sync passes ($OUT)"

# --- case 2: DRIFT — mutate a copied source, expect an actionable FAIL -------
printf '\nstray byte\n' >> "$TMPROOT/vision.md"
OUT="$(check_breadcrumbs "$TMPROOT" "docs/vision.html" 2>&1)"; RC=$?
{ [ "$RC" -ne 0 ] \
    && printf '%s' "$OUT" | grep -q 'vision.md' \
    && printf '%s' "$OUT" | grep -q 'vision.html' \
    && printf '%s' "$OUT" | grep -qi 'refresh its breadcrumb'; } \
  && ok "drifted vision.md fails naming file+source, actionable" \
  || bad "drifted vision.md fails naming file+source, actionable (rc=$RC: $OUT)"

# index.html mirrors vision.md too, so it must catch the same drift and name itself
OUT="$(check_breadcrumbs "$TMPROOT" "docs/index.html" 2>&1)"; RC=$?
{ [ "$RC" -ne 0 ] \
    && printf '%s' "$OUT" | grep -q 'vision.md' \
    && printf '%s' "$OUT" | grep -q 'index.html'; } \
  && ok "drifted vision.md also fails index.html naming itself" \
  || bad "drifted vision.md also fails index.html naming itself (rc=$RC: $OUT)"

# restore the source so the STRIPPED case starts clean
cp "$REPO_ROOT/vision.md" "$TMPROOT/vision.md"

# --- case 3: STRIPPED — remove breadcrumb lines from a copied html ----------
grep -v 'lcars-docs-src:' "$REPO_ROOT/docs/vision.html" > "$TMPROOT/docs/vision.html"
OUT="$(check_breadcrumbs "$TMPROOT" "docs/vision.html" 2>&1)"; RC=$?
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'vision.html'; } \
  && ok "stripped breadcrumb fails naming the html file" \
  || bad "stripped breadcrumb fails naming the html file (rc=$RC: $OUT)"

echo
printf 'docs-sync: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
