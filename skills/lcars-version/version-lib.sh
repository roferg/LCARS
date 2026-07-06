#!/usr/bin/env bash
#
# version-lib.sh — shared version helpers for the lcars-version scripts.
#
# Sourced by BOTH version.sh (the read-only reporter) and check.sh (the
# throttled check + ask-to-update helper) so the YYYY.M.N parse/compare rules
# and the running-version read live in exactly one place. Defines functions
# only; it runs nothing on its own.

# version_valid V -> 0 (true) iff V is a well-formed YYYY.M.N: exactly three
# dot-separated, non-empty, purely-numeric fields. Guards every read so a
# malformed / empty VERSION yields a readable error, never an arithmetic crash.
version_valid() {
  case "$1" in
    ''|*[!0-9.]*) return 1 ;;                       # empty or non-[0-9.] chars
  esac
  local IFS=.; set -f; set -- $1; set +f
  [ "$#" -eq 3 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]
}

# version_cmp A B -> echoes -1 (A<B), 0 (A==B), 1 (A>B). Compares FIELD-BY-FIELD
# NUMERICALLY (string compare is wrong: 2026.7.2 vs 2026.7.10 — 10 > 2). Assumes
# both are already version_valid.
version_cmp() {
  local a="$1" b="$2" ai bi i
  local -a af bf
  local IFS=.; set -f; af=($a); bf=($b); set +f; unset IFS
  for i in 0 1 2; do
    ai=$((10#${af[i]})); bi=$((10#${bf[i]}))
    if [ "$ai" -lt "$bi" ]; then echo -1; return; fi
    if [ "$ai" -gt "$bi" ]; then echo 1;  return; fi
  done
  echo 0
}

# lcars_version_read_running FILE -> print the first non-empty line of a VERSION
# file, whitespace-trimmed. Empty when the file is missing/blank (the caller then
# version_valid-guards the result).
lcars_version_read_running() {
  [ -f "$1" ] || return 0
  sed -n '/[^[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p; q;}' "$1"
}
