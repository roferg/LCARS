#!/usr/bin/env bash
# Crop a region out of an EXISTING png without re-taking it.
#
#   bash crop.sh <port> <src.png> <srcScale> <cssX> <cssY> <cssW> <cssH> <out.png> [outScale]
#
# The source shots are Number One's own, captured at deviceScaleFactor 2. To put
# a BEFORE and an AFTER of the same region side by side the two crops must be
# framed identically, so the region is given in the APP's CSS pixels and this
# converts. Nothing here re-runs the app: it lays the existing PNG out at its
# natural CSS size in a page and clips that.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="$1"; SRC="$2"; SS="$3"; X="$4"; Y="$5"; W="$6"; H="$7"; OUT="$8"; OS="${9:-3}"
SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
PW=$(sips -g pixelWidth "$SRC" | tail -1 | awk '{print $2}')
PH=$(sips -g pixelHeight "$SRC" | tail -1 | awk '{print $2}')
CW=$((PW / SS)); CH=$((PH / SS))
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/c.html" <<HTML
<style>html,body{margin:0;padding:0;background:#000}
img{display:block;width:${CW}px;height:${CH}px;image-rendering:auto}</style>
<img id="s" src="file://$SRC">
HTML
node "$HERE/shot.js" --port "$PORT" --url "file://$TMP/c.html" --wait "#s" \
  --width $((CW + 40)) --height $((CH + 40)) --scale "$OS" \
  --clip-box "$X,$Y,$W,$H" --settle 700 --out "$OUT"
