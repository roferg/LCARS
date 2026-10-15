#!/usr/bin/env bash

# Called only after completion; unlike `xo on`, this never re-engages Number One.
lcars_xo_release_completed_stop() { # <mission-dir>
  local dir="$1"
  local marker="$dir/xo-stop" kind who how state
  [ -f "$marker" ] || return 0
  [ "$(lcars_state_get_raw "$dir/state.json" stage)" = '"done"' ] || return 0
  while read -r kind who how; do
    case "$kind:$who:$how" in
      self:paused-by-us:) state="$dir/state.json" ;;
      child:*:paused-by-us)
        case "$who" in ''|.|..|*/*)
          printf 'LCARS: invalid child in stop record %s.\n' "$marker" >&2
          return 1 ;;
        esac
        state="${dir%/*}/$who/state.json"
        [ -f "$state" ] || continue ;;
      *) continue ;;
    esac
    lcars_state_unset "$state" paused || return 1
  done <"$marker"
  # Keep the ownership record if any release failed, so cleanup can be retried.
  rm -f "$marker"
}
