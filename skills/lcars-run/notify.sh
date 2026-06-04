#!/usr/bin/env bash
#
# lcars notify — the walk-away ping. `lcars run`'s driver calls this ONCE, and
# ONLY at a human gate (a stage escalated to awaiting-human, or the mission
# reached the Verify review gate). It never fires on a clean stage-to-stage
# transition — the whole point is that you are pinged only when you are actually
# needed.
#
#   notify.sh <mission-id> <gate-type> <one-line-summary>
#
#     gate-type        "verify" | "awaiting-human" (free-form; shown to you)
#     one-line-summary a decision-ready sentence — what it's asking + what each
#                      answer does — already assembled by the driver. A whole
#                      stage's questions are batched into this ONE line; never
#                      one notification per question.
#
# Delivery is layered, local-first:
#   • ALWAYS — a terminal bell + a one-line banner on stderr, and (on macOS) a
#     desktop notification. This is the zero-config default.
#   • OPT-IN — a phone push, if you have wired one:
#       ntfy      set LCARS_NTFY_TOPIC (or `notifyNtfyTopic` in
#                 .git/lcars/config.json); optional LCARS_NTFY_SERVER.
#       Pushover  set LCARS_PUSHOVER_TOKEN + LCARS_PUSHOVER_USER (or the
#                 `notifyPushover{Token,User}` config keys).
#
# Dependencies are taken via env so tests can stub them and assert the call
# without sending anything:
#   LCARS_NOTIFY     run.sh calls THIS script by default; point it elsewhere to
#                    swap the whole hook (this is the stub seam the tests use).
#   LCARS_CURL_BIN   the curl binary used for the opt-in push (default: curl).
#   LCARS_CFG        path to .git/lcars/config.json, for the opt-in push config.
#
set -uo pipefail

ID="${1:-?}"; GATE="${2:-gate}"; SUMMARY="${3:-}"
CURL_BIN="${LCARS_CURL_BIN:-curl}"
CFG="${LCARS_CFG:-}"

# --- tiny JSON reader (no jq; same style as run.sh / file.sh) --------------
cfg_str() { # key  → first matching "key": "value" in the config (or empty)
  [ -n "$CFG" ] && [ -f "$CFG" ] || return 0
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CFG" | head -1
}

# Env wins over config for every opt-in channel.
TOPIC="${LCARS_NTFY_TOPIC:-}";        [ -z "$TOPIC" ] && TOPIC="$(cfg_str notifyNtfyTopic)"
SERVER="${LCARS_NTFY_SERVER:-}";      [ -z "$SERVER" ] && SERVER="$(cfg_str notifyNtfyServer)"
[ -n "$SERVER" ] || SERVER="https://ntfy.sh"
PO_TOKEN="${LCARS_PUSHOVER_TOKEN:-}"; [ -z "$PO_TOKEN" ] && PO_TOKEN="$(cfg_str notifyPushoverToken)"
PO_USER="${LCARS_PUSHOVER_USER:-}";   [ -z "$PO_USER" ] && PO_USER="$(cfg_str notifyPushoverUser)"

TITLE="LCARS $ID"

# --- 1) the always-on local delivery: bell + banner (+ desktop on macOS) ----
# stderr, so a notification never pollutes a caller capturing stdout.
printf '\a' >&2
printf '🔔 %s — %s gate: %s\n' "$TITLE" "$GATE" "$SUMMARY" >&2
# The desktop banner is best-effort (macOS only) and can be silenced — set
# LCARS_NOTIFY_NO_DESKTOP=1 (the test suite does, so a run never pops a banner).
if [ -z "${LCARS_NOTIFY_NO_DESKTOP:-}" ] && command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"${SUMMARY//\"/\'}\" with title \"$TITLE\" subtitle \"$GATE gate\"" \
    >/dev/null 2>&1 || true
fi

# --- 2) the opt-in phone push ----------------------------------------------
# ntfy: a plain POST of the summary to <server>/<topic>, titled with the mission.
if [ -n "$TOPIC" ]; then
  "$CURL_BIN" -fsS \
    -H "Title: $TITLE ($GATE)" \
    -d "$SUMMARY" \
    "$SERVER/$TOPIC" >/dev/null 2>&1 || true
fi
# Pushover: needs both an app token and a user key.
if [ -n "$PO_TOKEN" ] && [ -n "$PO_USER" ]; then
  "$CURL_BIN" -fsS \
    --form-string "token=$PO_TOKEN" \
    --form-string "user=$PO_USER" \
    --form-string "title=$TITLE ($GATE)" \
    --form-string "message=$SUMMARY" \
    "https://api.pushover.net/1/messages.json" >/dev/null 2>&1 || true
fi

exit 0
