#!/usr/bin/env bash
# Fast, STANDALONE unit test for the S133 multi-dir placement arithmetic:
# `anchor_from_pairs` + `import_specs_in` (skill source: skills/lcars-run/run.sh).
#
# WHY: a SINGLE ticket test file can import sources that live in DIFFERENT dirs.
# The old placement co-located it next to the FIRST import's source, so every
# OTHER `./sibling` import broke → the red gate rejected every attempt → the
# ticket cap-exhausted (caught live on groutwork t-002, 2026-07-12).
# `anchor_from_pairs` derives the ONE dir the test must sit in so EVERY same-level
# import resolves IN PLACE, respecting each import's spelling.
#
# PURE STRING PARSING: extract the function bodies with sed, drive them with fixed
# strings. No runner, no model, no network, ZERO tokens. Safe to run directly.
#
# Usage: bash tests/coloc-anchor.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

LIB="$(mktemp)"; trap 'rm -f "$LIB"' EXIT
sed -n '/^anchor_from_pairs() {/,/^}/p' "$RUN_SH" >"$LIB"
sed -n '/^import_specs_in() {/,/^}/p'   "$RUN_SH" >>"$LIB"
# shellcheck source=/dev/null
. "$LIB"
type anchor_from_pairs >/dev/null 2>&1 || { echo "FATAL: anchor_from_pairs not extracted" >&2; exit 1; }

# anchor <ua> <pair-lines> → sets GOT + RC (exit code)
anchor() { GOT="$(printf '%b' "$2" | anchor_from_pairs "$1")"; RC=$?; }

echo "S133 anchor_from_pairs — the co-located dir a file's imports agree on"

# A. two ./descendants across dirs AGREE on the common ancestor (t-002 shape)
anchor 0 './App\tsrc/App.tsx\n./components/MapCanvas/MapCanvas\tsrc/components/MapCanvas/MapCanvas.tsx\n./state/editorStore\tsrc/state/editorStore.ts\n'
{ [ "$RC" -eq 0 ] && [ "$GOT" = "src" ]; } \
  && ok "A. ./App + ./components/MapCanvas/MapCanvas + ./state/editorStore → src" \
  || bad "A. expected src (rc0), got '$GOT' rc=$RC"

# B. a single bare sibling → its own dir (byte-identical to legacy single-dir)
anchor 0 './bar\tsrc/b/bar.ts\n'
{ [ "$RC" -eq 0 ] && [ "$GOT" = "src/b" ]; } \
  && ok "B. single ./bar → src/b" || bad "B. expected src/b, got '$GOT' rc=$RC"

# C. co-located sibling + a ../reach-out util → anchors on the SIBLING (no hoist)
anchor 0 './editorCanvas\tsrc/canvas/editorCanvas.ts\n../utils/isDefaultViewport\tsrc/utils/isDefaultViewport.ts\n'
{ [ "$RC" -eq 0 ] && [ "$GOT" = "src/canvas" ]; } \
  && ok "C. ./editorCanvas + ../utils/x → src/canvas (reach-out ignored, NOT hoisted)" \
  || bad "C. expected src/canvas, got '$GOT' rc=$RC"

# D. two BARE siblings in different dirs CONFLICT → exit 1 (caller falls back → hint)
anchor 0 './App\tsrc/App.tsx\n./MapCanvas\tsrc/components/MapCanvas/MapCanvas.tsx\n'
[ "$RC" -ne 0 ] \
  && ok "D. bare ./App + bare ./MapCanvas (different dirs) → conflict, exit 1" \
  || bad "D. expected exit 1, got '$GOT' rc=$RC"

# E. no same-level anchoring import at all (co-located, everything reaches out) → exit 1
anchor 0 '../x/y\tsrc/x/y.ts\n'
[ "$RC" -ne 0 ] \
  && ok "E. only ../reach-out imports under co-located → no anchor, exit 1" \
  || bad "E. expected exit 1, got '$GOT' rc=$RC"

# F. root-level source → anchor is "" (package/repo root), exit 0
anchor 0 './index\tindex.ts\n'
{ [ "$RC" -eq 0 ] && [ -z "$GOT" ]; } \
  && ok "F. ./index at root → empty anchor (root), exit 0" \
  || bad "F. expected empty/rc0, got '$GOT' rc=$RC"

# --- __tests__ convention (ua=1): a ../descendant exits the __tests__/ dir ------
# G. multi-dir __tests__ imports agree on the ancestor (test sits at <ancestor>/__tests__)
anchor 1 '../App\tsrc/App.tsx\n../components/MapCanvas/MapCanvas\tsrc/components/MapCanvas/MapCanvas.tsx\n'
{ [ "$RC" -eq 0 ] && [ "$GOT" = "src" ]; } \
  && ok "G. __tests__ ../App + ../components/MapCanvas/MapCanvas → src" \
  || bad "G. expected src (rc0), got '$GOT' rc=$RC"

# H. __tests__ single ../sibling → the module's own dir
anchor 1 '../bar\tsrc/b/bar.ts\n'
{ [ "$RC" -eq 0 ] && [ "$GOT" = "src/b" ]; } \
  && ok "H. __tests__ single ../bar → src/b" || bad "H. expected src/b, got '$GOT' rc=$RC"

# --- import_specs_in: only RELATIVE specifiers, both from/import forms ----------
TF="$(mktemp)"; trap 'rm -f "$LIB" "$TF"' EXIT
cat >"$TF" <<'TS'
import { App } from './App';
import { render } from '@testing-library/react';
import './components/MapCanvas/MapCanvas';
const x = require('../state/editorStore');
TS
SPECS="$(import_specs_in "$TF" | paste -sd',' -)"
[ "$SPECS" = "./App,./components/MapCanvas/MapCanvas,../state/editorStore" ] \
  && ok "I. import_specs_in → only the 3 relative specifiers (bare package dropped)" \
  || bad "I. relative specifiers (got '$SPECS')"

echo
printf 'coloc-anchor: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
