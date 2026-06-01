#!/usr/bin/env bash
#
# lcars version — print the installed LCARS version.
#
# Reads the VERSION file that sits next to this script, trims surrounding
# whitespace, and prints "LCARS <version>". If VERSION is missing or
# unreadable it prints "LCARS unknown" and exits non-zero.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"

if [ ! -r "$VERSION_FILE" ]; then
  echo "LCARS unknown"
  exit 1
fi

version="$(cat "$VERSION_FILE")"
# Trim leading/trailing whitespace (incl. the trailing newline).
version="${version#"${version%%[![:space:]]*}"}"
version="${version%"${version##*[![:space:]]}"}"

if [ -z "$version" ]; then
  echo "LCARS unknown"
  exit 1
fi

echo "LCARS $version"
exit 0
