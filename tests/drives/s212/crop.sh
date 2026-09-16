#!/usr/bin/env bash
# crop.sh <in.png> <out.png> <cssX> <cssY> <cssW> <cssH>   (2x source)
set -euo pipefail
in="$1"; out="$2"; x=$(( $3 * 2 )); y=$(( $4 * 2 )); w=$(( $5 * 2 )); h=$(( $6 * 2 ))
sips -s format png "$in" --out "$out" >/dev/null
sips --cropOffset "$y" "$x" -c "$h" "$w" "$out" >/dev/null
