#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
printf '%-26s %-11s %-14s %s\n' REPO STATUS FOUNDATION LINE
printf '%.0s-' {1..140}; echo
for d in "$FIX_ROOT"/*/; do
  n="$(basename "$d")"
  v="$(verdict "$d")"
  s="$(echo "$v" | cut -f1)"; f="$(echo "$v" | cut -f2 | tr -d '"')"
  l="$(line "$d" | head -1)"
  printf '%-26s %-11s %-14s %s\n' "$n" "$s" "$f" "${l:-<silent>}"
done
