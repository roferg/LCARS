#!/usr/bin/env bash
# Count the glob keys the RUNNING dev server is actually serving.
#
# Usage: probe.sh <url-of-transformed-data-index.js>
# Prints a bare integer (0 if the server is unreachable or serving something else).
#
# Vite's eager `import.meta.glob` transform emits a literal map into the served
# module:
#   const mods = Object.assign({"./data/alpha.json": …,"./data/beta.json": …});
# so counting the distinct `"./data/*.json"` string literals is a count of what the
# server BELIEVES is on disk right now.
#
# The `sourceMappingURL` cut is load-bearing: Vite appends an inline base64
# sourcemap that contains the SAME text again, which would double every count.
# (Cutting there rather than taking the first line is deliberate — the transform
# does not promise the map lands on any particular line, and an earlier version of
# this probe that assumed line 1 silently counted 0 on every request.)
curl -s -m 5 "$1" \
  | sed '/sourceMappingURL/,$d' \
  | grep -o '"\./data/[A-Za-z0-9_.-]*\.json"' \
  | sort -u | wc -l | tr -d ' '
