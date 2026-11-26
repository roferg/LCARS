#!/usr/bin/env bash
#
# usage.sh — how much of the captain's Claude plan is left, and may the chain
# start another session.
#
#   usage.sh read [--json]      the numbers (one human line, or normalised JSON)
#   usage.sh gate [--json]      GO / HOLD / ASK / UNKNOWN  -> exit 0 / 2 / 3 / 4
#                               (--json: the same verdict, same exit code, for a
#                                caller that must not parse prose)
#   usage.sh config             the thresholds in force
#
# The account's own usage endpoint is the PRIMARY source (verified HTTP 200 on
# 2026-09-11): GET https://api.anthropic.com/api/oauth/usage, bearer = the OAuth
# access token Claude Code keeps in the macOS Keychain.
#
# Two rules this script exists to keep:
#   * It NEVER refreshes the OAuth token. Claude Code rotates that Keychain item;
#     a self-refresh desyncs the stored pair. The token is re-read on every call
#     and never cached. An expired one is REPORTED, not repaired.
#   * It never hammers an undocumented endpoint: one request per call at most,
#     answers cached for 180 s, no retry loop, and a non-200 degrades (stale
#     cache -> statusLine snapshot -> unknown) instead of failing the caller.
#
# Every external touch is env-injected so tests need no network and no Keychain:
#   CHAIN_CURL_BIN      curl binary                  (default: curl)
#   CHAIN_KEYCHAIN_CMD  the Keychain read command     (default: the security line)
#   CHAIN_KEYCHAIN_TIMEOUT  seconds the credential read may take (default: 5)
#   CHAIN_NOW           epoch seconds "now"           (default: date +%s)
#   CHAIN_CACHE_DIR     cache + statusLine snapshot   (default: ~/.cache/lcars/usage)
#   CHAIN_CONFIG        thresholds file               (default: beside this script, usage.json)
#   CHAIN_USAGE_URL     the endpoint PATH on https://api.anthropic.com — any
#                       other scheme or host, or any whitespace/control character
#                       in it, exits 64 and no header is attached
# CLAUDE_CODE_OAUTH_TOKEN, if set, wins over the Keychain (Claude Code's own rule).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

UA_VERSION="2.1.269"
USAGE_URL="${CHAIN_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
CURL_BIN="${CHAIN_CURL_BIN:-curl}"
# The service name contains a space, so the default is assigned on its own line
# with the inner quoting intact — folding it into a ${VAR:-default} expansion
# silently splits it into three arguments (found by running the real product).
KEYCHAIN_CMD="${CHAIN_KEYCHAIN_CMD:-}"
[ -n "$KEYCHAIN_CMD" ] || KEYCHAIN_CMD="security find-generic-password -s 'Claude Code-credentials' -w"
CACHE_DIR="${CHAIN_CACHE_DIR:-$HOME/.cache/lcars/usage}"
CONFIG_FILE="${CHAIN_CONFIG:-$SELF_DIR/usage.json}"
CACHE_FILE="$CACHE_DIR/usage.json"
STATUSLINE_FILE="$CACHE_DIR/statusline.json"
NOW="${CHAIN_NOW:-$(date +%s)}"

CACHE_FRESH_SECONDS=180     # the poll floor: never ask the endpoint faster
CACHE_STALE_SECONDS=900     # a failed read may serve a cache this old, flagged
# The credential read is BOUNDED. The real Keychain lookup below can block
# indefinitely on a locked keychain or an ACL prompt, and nothing bounded
# `eval "$KEYCHAIN_CMD"`: a 20-second block was measured. In an unattended
# chain that is a silent stall — the same shape as the parser hang cured in
# round 1, through a different door. A token that cannot be read in time is
# simply unreadable, which the verdict chokepoint already knows how to answer.
KEYCHAIN_TIMEOUT="${CHAIN_KEYCHAIN_TIMEOUT:-5}"
case "$KEYCHAIN_TIMEOUT" in ''|*[!0-9]*) KEYCHAIN_TIMEOUT=5 ;; esac

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/session-chain.XXXXXX")" || TMPD=""
[ -n "$TMPD" ] || { printf 'usage.sh: no writable temp directory\n' >&2; exit 64; }
trap 'rm -rf "$TMPD"' EXIT
PY_LIB_DIR="$TMPD"

die() { printf '%s\n' "$*" >&2; exit 64; }

# ---------------------------------------------------------------------------
# where the bearer may go (BUG-088, half two)
# ---------------------------------------------------------------------------
# CHAIN_USAGE_URL used to be honoured as given, with no scheme or host check
# anywhere, and the Authorization header was attached unconditionally. So one
# environment variable did two harms at once: `CHAIN_USAGE_URL=http://elsewhere/x`
# FABRICATED a verdict (a tester got `GO — 5-hour window at 3% used` out of a
# stub listener) and shipped the live OAuth bearer to that host in clear. The
# thing consuming this reader is an unattended loop, which makes a forged GO and
# a stolen credential the same single keystroke.
#
# The rule is therefore absolute and not configurable: https, and the host
# exactly `api.anthropic.com`. The patterns demand a `/` or `?` immediately
# after the host, which is what refuses the two lookalikes that would otherwise
# pass a naive prefix test — `https://api.anthropic.com@evil/x` (userinfo) and
# `https://api.anthropic.com.evil/x` (suffix).
#
# Tests do not need this relaxed: they stub CHAIN_CURL_BIN, which is how a stub
# belongs to be injected, and point CHAIN_USAGE_URL at a path on the real host.
usage_url_ok() { # usage_url_ok <url>
  # Whitespace and control characters first, because the host globs below anchor
  # only the FRONT of the string and said nothing about the rest of it: the glob
  # `https://api.anthropic.com/*` happily matched
  # `https://api.anthropic.com/x<LF>https://127.0.0.1/y` and the CRLF
  # `Host:`-injection variant, so a request was built and the credential header
  # file was attached. That was never exploitable — the whole string reaches curl
  # as ONE argument and curl answers `URL rejected: Malformed input to a URL
  # function` with zero TCP connections — but the promise this skill documents is
  # that anything else exits 64 BEFORE a request is built, and that promise was
  # being kept by curl's parser rather than by this function. A URL has no
  # legitimate reason to contain a space, a tab, a newline or any control byte.
  case "$1" in
    *[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
  esac
  case "$1" in
    https://api.anthropic.com|https://api.anthropic.com/*|https://api.anthropic.com\?*)
      return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# the ONE validation chokepoint, shared by every python block below
# ---------------------------------------------------------------------------
# Written to the per-run temp dir rather than shipped as a second file, so the
# skill stays one executable. Every python block that touches a usage number
# imports from here; there is deliberately no second copy of these rules.
cat >"$TMPD/chainlib.py" <<'CHAINLIB'
"""The rules a usage number must satisfy before any verdict can see it.

Why this file exists at all. Four input paths feed the verdict — the account
endpoint, the 180 s cache, the statusLine snapshot, and a manual override — and
validation used to live in exactly ONE of them, the argument parser. So the same
harm (a false GO that silently deletes the weekly ASK guard) came back three fix
rounds running, by three different routes: a non-numeric --weekly, an omitted
--weekly, and a weekly number that was unreadable in the DATA. Patching the
route is what kept failing. These functions are the layer that was missing, and
a FIFTH input path inherits them for free.
"""
import math

PCT_MIN, PCT_MAX = 0.0, 100.0
GRACE_MINUTES_MAX = 600.0          # the 5-hour window is five hours


def as_pct(v):
    """A usable usage percentage, or None when the value is not one.

    Rejects, with the observed harm each one caused:
      * bools   — `True <= 70` is True in Python, so a cached {"pct": true}
                  printed `GO - 5-hour window at 1% used`.
      * strings — a hand-edited or hostile cache carrying "95" compared fine
                  against nothing and the guard vanished.
      * NaN / Infinity — json.load parses bare NaN and Infinity, and every
                  comparison against NaN is False, which read as "not over the
                  threshold".
      * out of 0-100 — a cached {"pct": -50} printed `GO ... at -50% used`,
                  the exact value the argument parser already refused.
    """
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    v = float(v)
    if not math.isfinite(v) or v < PCT_MIN or v > PCT_MAX:
        return None
    return v


def as_epoch(v):
    """An epoch-seconds timestamp, or None. Same bool/NaN rules as as_pct."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    v = float(v)
    if not math.isfinite(v):
        return None
    return int(v)


def as_threshold(v, lo, hi):
    """A threshold from chain.json, or None when it is unusable.

    A string "70" is still a number a human meant, so it is accepted; NaN,
    Infinity, a bool and anything outside [lo, hi] are not. `weeklyAsk: 101`
    made the ASK guard unreachable and `fiveHourGo: 700` disabled the GO rule,
    both in total silence.
    """
    if isinstance(v, bool):
        return None
    if not isinstance(v, (int, float)):
        try:
            v = float(v)
        except (TypeError, ValueError):
            return None
    v = float(v)
    if not math.isfinite(v) or v < lo or v > hi:
        return None
    return v


def canonical(d, now):
    """Re-judge a document from ANY input path into the one shape the rest of
    the script may consume: source, readAt, fiveHour{pct,resetsAt},
    weekly{pct,resetsAt}, note. Every number goes through as_pct / as_epoch, so
    a value no path validated cannot reach a verdict, a rendering or a cache.
    A discarded number is NAMED in the note rather than silently becoming
    absent, because 'unreadable' and 'not reported' are different stories for
    whoever reads the morning log.
    """
    notes = []
    if not isinstance(d, dict):
        d = {}
    src = d.get("source")
    if not isinstance(src, str) or not src:
        src = "unknown"

    def window(key, label):
        obj = d.get(key)
        raw = obj.get("pct") if isinstance(obj, dict) else obj
        pct = as_pct(raw)
        if pct is None and raw is not None:
            notes.append("the %s number was unusable and has been discarded" % label)
        reset = as_epoch(obj.get("resetsAt")) if isinstance(obj, dict) else None
        out = {"pct": pct, "resetsAt": reset}
        # `reported` is carried through ONLY as the literal False, and only on
        # the five-hour window. It is the gate's licence to decide on the weekly
        # alone (the captain's plan stopped having a 5-hour window), so it is
        # re-judged here like every other value rather than trusted: an absent,
        # truthy or garbage `reported` is simply left OFF the canonical document,
        # and the gate's `is False` test then reads it as "I do not know" and
        # fails safe to UNKNOWN. One key, one direction, no guessing.
        if key == "fiveHour" and isinstance(obj, dict) and obj.get("reported") is False:
            out["reported"] = False
        return out

    five = window("fiveHour", "5-hour")
    week = window("weekly", "weekly")
    read_at = as_epoch(d.get("readAt"))
    if read_at is None:
        read_at = int(now)
    note = d.get("note")
    note = note if isinstance(note, str) else ""
    if notes:
        note = (note + "; " if note else "") + "; ".join(notes)
    return {"source": src, "readAt": read_at,
            "fiveHour": five, "weekly": week, "note": note}
CHAINLIB

# run_bounded <seconds> <shell-command> -> the command's stdout; exit 124 on
# timeout, 125 if it could not be started. The child gets its OWN session and
# the whole process GROUP is killed on timeout, so nothing outlives the call
# holding a pipe open. (A `perl -e alarm` cage was tried and does not reliably
# kill this shape; macOS has no GNU `timeout`.)
run_bounded() {
  BND_SECS="$1" BND_CMD="$2" python3 <<'PY'
import os, signal, subprocess, sys
secs, cmd = float(os.environ["BND_SECS"]), os.environ["BND_CMD"]
try:
    p = subprocess.Popen(["/bin/sh", "-c", cmd], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         start_new_session=True)
except Exception:
    sys.exit(125)
try:
    out = p.communicate(timeout=secs)[0]
except subprocess.TimeoutExpired:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except Exception:
        pass
    p.wait()
    sys.exit(124)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(p.returncode)
PY
}

usage_text() {
  cat <<'TXT'
usage: usage.sh <read|gate|config|help> [options]

  read  [--json]                      the current 5-hour and weekly numbers
  gate  [--json]                      may the chain start another session?
                                        exit 0 GO · 2 HOLD · 3 ASK · 4 UNKNOWN
                                        --json adds one JSON object with the
                                        verdict, the exit code, the reason and
                                        both windows
  config                              the thresholds in force
  help                                this text (so does --help)

  --fresh                             step over the 180 s cache and ask the
                                        account again — ONE request, not a
                                        retry loop, and the answer is written
                                        back to the cache. For a caller that
                                        re-gates before every session, where a
                                        cache warmed before the LAST session
                                        would gate the next one on stale
                                        numbers. Ignored alongside a manual
                                        override, which reads nothing anyway.

  manual override (for the day the read fails; works on read and gate):
    --five-hour N  --weekly N  [--five-hour-resets-in MINUTES]
      the two percentages (0-100) are a PAIR — both or neither; MINUTES is
      optional, 0-600, and only legal alongside a complete pair.
TXT
}

# ---------------------------------------------------------------------------
# thresholds
# ---------------------------------------------------------------------------
read_config() {
  CFG_FILE="$CONFIG_FILE" PY_LIB_DIR="$PY_LIB_DIR" python3 <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["PY_LIB_DIR"])
from chainlib import as_threshold, PCT_MIN, PCT_MAX, GRACE_MINUTES_MAX

# A garbage / empty / null / directory chain.json always degraded correctly,
# because json.load was wrapped. A WRONG-TYPED `thresholds` key did not: only
# json.load was in the try, so `"nope".get` and `[1,2,3].get` raised, the whole
# block exited 1, the four numbers came back EMPTY, and gate_verdict then died
# on float("") with a traceback and no verdict word. Both the parse and the
# lookup are guarded now, and each threshold is range-checked.
DEFAULTS = (("fiveHourGo", 70.0, PCT_MIN, PCT_MAX),
            ("fiveHourGrace", 80.0, PCT_MIN, PCT_MAX),
            ("graceMinutes", 45.0, 0.0, GRACE_MINUTES_MAX),
            ("weeklyAsk", 70.0, PCT_MIN, PCT_MAX))

def warn(msg):
    sys.stderr.write("usage.sh: %s\n" % msg)

raw = {}
p = os.environ.get("CFG_FILE", "")
if p and os.path.isfile(p):
    try:
        doc = json.load(open(p))
    except Exception:
        doc = None
    if isinstance(doc, dict):
        t = doc.get("thresholds")
        if isinstance(t, dict):
            raw = t
        elif t is not None:
            warn("the thresholds key in %s is not an object - using the "
                 "built-in defaults 70/80/45/70" % p)

out = []
for key, default, lo, hi in DEFAULTS:
    if key not in raw:
        out.append(default)
        continue
    v = as_threshold(raw[key], lo, hi)
    if v is None:
        # Silence here is the whole defect: a fat-fingered 700 for 70 disabled
        # the GO rule and nothing said a word.
        warn("threshold %s in %s is not a number between %g and %g - using "
             "the built-in default %g" % (key, p, lo, hi, default))
        v = default
    out.append(v)
print("%g %g %g %g" % tuple(out))
PY
}

# ---------------------------------------------------------------------------
# the token — re-read every call, never cached, NEVER refreshed
# ---------------------------------------------------------------------------
# Sets TOKEN (may be empty) and TOKEN_NOTE (empty when the token is usable).
load_token() {
  TOKEN=""
  TOKEN_NOTE=""
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
    return 0
  fi
  local raw="" kc_rc=0
  raw="$(run_bounded "$KEYCHAIN_TIMEOUT" "$KEYCHAIN_CMD" 2>/dev/null)" || kc_rc=$?
  if [ "$kc_rc" = 124 ]; then
    TOKEN_NOTE="the Keychain did not answer within ${KEYCHAIN_TIMEOUT}s - unlock the login keychain, or set CLAUDE_CODE_OAUTH_TOKEN"
    return 0
  fi
  [ "$kc_rc" = 0 ] || raw=""
  if [ -z "$raw" ]; then
    TOKEN_NOTE="no Claude Code credentials found — sign in to Claude Code once"
    return 0
  fi
  printf '%s' "$raw" >"$TMPD/kc.json"
  local parsed
  parsed="$(KC_FILE="$TMPD/kc.json" NOW="$NOW" python3 <<'PY'
import json, os
try:
    d = json.load(open(os.environ["KC_FILE"])) or {}
except Exception:
    print("ERR\tcould not read the Claude Code credentials — open Claude Code once")
    raise SystemExit(0)
oauth = d.get("claudeAiOauth") or {}
tok = oauth.get("accessToken") or ""
if not tok:
    print("ERR\tno Claude Code access token found — open Claude Code once to sign in")
    raise SystemExit(0)
exp = oauth.get("expiresAt")          # epoch MILLISECONDS on macOS
try:
    if exp is not None and float(exp) / 1000.0 < float(os.environ["NOW"]):
        print("ERR\ttoken expired — open Claude Code once to refresh it")
        raise SystemExit(0)
except (TypeError, ValueError):
    pass
print("OK\t" + tok)
PY
)"
  rm -f "$TMPD/kc.json"
  case "$parsed" in
    OK*)  TOKEN="${parsed#OK$'\t'}" ;;
    *)    TOKEN_NOTE="${parsed#ERR$'\t'}" ;;
  esac
}

# ---------------------------------------------------------------------------
# the read
# ---------------------------------------------------------------------------
# normalise_endpoint <raw-body-file> -> normalised JSON on stdout, or exit 1
normalise_endpoint() {
  RAW_FILE="$1" NOW="$NOW" PY_LIB_DIR="$PY_LIB_DIR" python3 <<'PY'
import json, os, sys, datetime
sys.path.insert(0, os.environ["PY_LIB_DIR"])
from chainlib import as_pct, as_epoch

def epoch(v):
    """ISO-8601 (endpoint) or a number (statusLine) -> epoch seconds."""
    if v is None:
        return None
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return as_epoch(v)
    if not isinstance(v, str) or not v.strip():
        return None
    s = v.strip().replace("Z", "+00:00")
    try:
        dt = datetime.datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return int(dt.timestamp())

def pct_of(obj):
    """A window object may call it `utilization` (five_hour/seven_day) or
    `percent` (a limits[] entry). Either is fine; anything else is absent.
    The judgement of WHAT is a usable percentage is as_pct's, not a second copy
    of it here: this function only knows which keys to look in."""
    if not isinstance(obj, dict):
        return None
    for key in ("utilization", "percent", "used_percentage"):
        v = as_pct(obj.get(key))
        if v is not None:
            return v
    return None

def window(obj):
    return (pct_of(obj), epoch(obj.get("resets_at")) if isinstance(obj, dict) else None)

try:
    d = json.load(open(os.environ["RAW_FILE"]))
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)

# NOTE: we look up only the keys we need and require none of them. The real
# 2026-09-11 response carried 21 top-level keys, most undocumented; unknown keys
# must never break the read and missing ones must never be fatal.
five = window(d.get("five_hour"))
week = window(d.get("seven_day"))

# Did the account report a 5-hour window AT ALL? Two different facts arrive at
# the gate as "no five-hour percentage", and it has to tell them apart:
#   present but unreadable -> a guard that cannot be EVALUATED is never a GO
#   not present at all     -> there is no window to be near; the weekly decides
# Measured on the captain's own account, 2026-11-04 17:54 PST: the endpoint
# answers `"five_hour": null` alongside a perfectly readable `seven_day` at 69%
# and a `limits[]` carrying only weekly entries. His plan has no 5-hour window
# any more. Reading that as UNKNOWN stopped an unattended chain dead with 26
# points of weekly budget sitting untouched, which is the whole reason this
# field exists. `is not None` covers both the absent key and the explicit null.
five_reported = d.get("five_hour") is not None

limits = d.get("limits")
if isinstance(limits, list):
    for entry in limits:
        if not isinstance(entry, dict):
            continue
        kind = str(entry.get("kind") or "")
        group = str(entry.get("group") or "")
        scoped = entry.get("scope") is not None
        if five[0] is None and not scoped and (kind == "session" or group == "session"):
            five = window(entry)
            five_reported = True      # a session entry IS the window, reported
        if week[0] is None and not scoped and (kind == "weekly_all" or group == "weekly"):
            week = window(entry)

if five[0] is None and week[0] is None:
    sys.exit(1)

notes = []
if five[0] is None:
    notes.append("the 5-hour window was not reported")
if week[0] is None:
    notes.append("the weekly window was not reported by the endpoint")

print(json.dumps({
    "source": "endpoint",
    "readAt": int(os.environ["NOW"]),
    "fiveHour": {"pct": five[0], "resetsAt": five[1], "reported": five_reported},
    "weekly":   {"pct": week[0], "resetsAt": week[1]},
    "note": "; ".join(notes),
}))
PY
}

# normalise_statusline -> normalised JSON on stdout, or exit 1
normalise_statusline() {
  SL_FILE="$STATUSLINE_FILE" NOW="$NOW" MAXAGE="$CACHE_STALE_SECONDS" \
  PY_LIB_DIR="$PY_LIB_DIR" python3 <<'PY'
import json, os, sys, time
sys.path.insert(0, os.environ["PY_LIB_DIR"])
from chainlib import as_pct, as_epoch
path = os.environ["SL_FILE"]
if not os.path.exists(path):
    sys.exit(1)
age = time.time() - os.path.getmtime(path)
# age < 0 is a snapshot stamped in the FUTURE. It is not fresh, it is wrong —
# the same arithmetic hole that froze the 180 s cache (see cached_read).
if age < 0 or age > float(os.environ["MAXAGE"]):
    sys.exit(1)
try:
    d = json.load(open(path)) or {}
except Exception:
    sys.exit(1)
rl = d.get("rate_limits") or d
def win(obj):
    if not isinstance(obj, dict):
        return (None, None)
    pct = as_pct(obj.get("used_percentage", obj.get("utilization")))
    return (pct, as_epoch(obj.get("resets_at")))   # statusLine: epoch SECONDS
five = win(rl.get("five_hour"))
week = win(rl.get("seven_day"))
if five[0] is None and week[0] is None:
    sys.exit(1)
print(json.dumps({
    "source": "statusline",
    "readAt": int(os.environ["NOW"]),
    "fiveHour": {"pct": five[0], "resetsAt": five[1]},
    "weekly":   {"pct": week[0], "resetsAt": week[1]},
    "note": "from a statusLine snapshot, not the account endpoint",
}))
PY
}

# cached_read <max-age-seconds> [stale-flag] -> cached JSON on stdout, or exit 1
cached_read() {
  CACHE_FILE="$CACHE_FILE" NOW="$NOW" MAXAGE="$1" FLAG="${2:-}" \
  PY_LIB_DIR="$PY_LIB_DIR" python3 <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["PY_LIB_DIR"])
from chainlib import as_epoch
path = os.environ["CACHE_FILE"]
if not os.path.exists(path):
    sys.exit(1)
try:
    d = json.load(open(path))
except Exception:
    sys.exit(1)
if not isinstance(d, dict) or d.get("source") != "endpoint":
    sys.exit(1)
now = int(os.environ["NOW"])
read_at = as_epoch(d.get("readAt"))
if read_at is None:                  # int(d.get("readAt") or 0) used to raise
    sys.exit(1)
age = now - read_at
# A NEGATIVE age means the entry is stamped in the FUTURE, and `age > MAXAGE`
# called that fresh — so the entry stayed fresh forever, the endpoint was never
# asked again, and a GO froze across five iterations while the real answer was
# HOLD, with no [stale] marker. Reachable by NTP correcting a fast clock
# backwards, or by one debug run using the CHAIN_NOW seam against the default
# cache dir. An entry from the future is unusable, not fresh.
if age < 0 or age > float(os.environ["MAXAGE"]):
    sys.exit(1)
if os.environ.get("FLAG") == "stale":
    mins = int(round(age / 60.0))
    note = "stale %d min — the endpoint did not answer, these are the last good numbers" % mins
    d["note"] = (d.get("note") + "; " + note) if d.get("note") else note
print(json.dumps(d))
PY
}

unknown_read() {
  NOTE="$1" NOW="$NOW" python3 <<'PY'
import json, os
print(json.dumps({
    "source": "unknown",
    "readAt": int(os.environ["NOW"]),
    "fiveHour": {"pct": None, "resetsAt": None},
    "weekly":   {"pct": None, "resetsAt": None},
    "note": os.environ["NOTE"],
}))
PY
}

override_read() {
  OV5="$OPT_FIVE" OV7="$OPT_WEEKLY" OVIN="$OPT_RESETS_IN" NOW="$NOW" python3 <<'PY'
import json, os
now = int(os.environ["NOW"])
def num(v):
    v = (v or "").strip()
    if v == "":
        return None
    try:
        return float(v)
    except ValueError:
        return None
five, week, mins = num(os.environ["OV5"]), num(os.environ["OV7"]), num(os.environ["OVIN"])
print(json.dumps({
    "source": "override",
    "readAt": now,
    "fiveHour": {"pct": five, "resetsAt": int(now + mins * 60) if mins is not None else None},
    "weekly":   {"pct": week, "resetsAt": None},
    "note": "manual override — no account read was made",
}))
PY
}

# canonical_read <raw-file> -> the one document shape the rest of the script may
# consume, on stdout. This is the SINGLE place a usage number earns the right to
# be believed: every input path's output passes through it, so a path added
# later cannot re-open the hole three fix rounds kept re-opening.
canonical_read() {
  RAW_FILE="$1" NOW="$NOW" PY_LIB_DIR="$PY_LIB_DIR" python3 <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["PY_LIB_DIR"])
from chainlib import canonical
try:
    d = json.load(open(os.environ["RAW_FILE"]))
except Exception:
    d = {"source": "unknown",
         "note": "the usage reader produced nothing this reader could parse"}
print(json.dumps(canonical(d, int(os.environ["NOW"]))))
PY
}

# resolve_usage -> the validated JSON for this invocation, on stdout.
resolve_usage() {
  resolve_usage_raw >"$TMPD/raw.json" 2>/dev/null
  canonical_read "$TMPD/raw.json"
}

# resolve_usage_raw -> whichever input path answers first, UNvalidated.
resolve_usage_raw() {
  # 1. a manual override short-circuits everything: no Keychain, no network.
  if [ -n "$OPT_FIVE" ] || [ -n "$OPT_WEEKLY" ] || [ -n "$OPT_RESETS_IN" ]; then
    override_read
    return 0
  fi

  # 2. the 180 s poll floor — unless the caller asked for a fresh read.
  # NOTE the asymmetry, which is deliberate: --fresh skips the cache on the way
  # IN only. The degrade path at step 5 still serves a stale cache when the
  # endpoint does not answer, because "I could not reach the account" is a worse
  # answer than "here are the last good numbers, 7 minutes old, and I have said
  # so". --fresh means ask again; it does not mean fail harder.
  local cached
  if [ "$OPT_FRESH" != 1 ] &&
     cached="$(cached_read "$CACHE_FRESH_SECONDS" 2>/dev/null)" && [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    return 0
  fi

  # 3. the token (re-read every call; never refreshed).
  load_token
  local fail_note="$TOKEN_NOTE"

  # 4. one request, no retry loop.
  # The destination is re-checked HERE as well as at startup, because this is
  # the line that ATTACHES the credential and the rule belongs where the harm
  # would happen. Argv validation already refused a bad URL, so this is a net,
  # not the check — and it degrades (no request, a named reason) rather than
  # dying, because this function's stdout is redirected into a file and a die
  # here would lose its own message.
  if [ -n "$TOKEN" ] && ! usage_url_ok "$USAGE_URL"; then
    fail_note="refusing to send the OAuth bearer to $USAGE_URL — only https://api.anthropic.com is allowed"
    TOKEN=""
  fi
  if [ -n "$TOKEN" ]; then
    local body="$TMPD/body.json" http="" hdr=""
    : >"$body"
    # The bearer NEVER becomes a process argument (BUG-088, half one). Process
    # arguments are readable by every process running as the captain, so
    # `-H "Authorization: Bearer $TOKEN"` put the live credential in `ps` for
    # the ~5 s of every single call — a tester confirmed it from the outside by
    # logging a stub curl's argv. curl reads the header out of a file instead
    # (`-H @file`, supported since 7.55; macOS ships 8.7). The file is made by
    # mktemp INSIDE $TMPD — a 0700 dir already removed by the EXIT trap — is
    # chmod 0600 before the token is written into it, and is deleted the moment
    # the call returns rather than waiting for the trap.
    # No failure branch and no `die` here on purpose: a die inside this function
    # would lose its own message (the caller redirects this stdout to a file and
    # this stderr to /dev/null), and a header file that could not be written
    # already degrades correctly — curl then fails and the read becomes "the
    # usage endpoint could not be reached", which is true.
    hdr="$(mktemp "$TMPD/hdr.XXXXXX" 2>/dev/null)" || hdr="$TMPD/hdr.authorization"
    ( umask 077; : >"$hdr" ) 2>/dev/null
    chmod 600 "$hdr" 2>/dev/null || true
    printf 'Authorization: Bearer %s\n' "$TOKEN" >"$hdr" 2>/dev/null
    http="$("$CURL_BIN" -sS -m 5 -o "$body" -w '%{http_code}' \
      -H "@$hdr" \
      -H "Content-Type: application/json" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-cli/$UA_VERSION (external, cli)" \
      "$USAGE_URL" 2>/dev/null)" || http=""
    rm -f "$hdr"
    if [ "$http" = "200" ]; then
      local norm
      if norm="$(normalise_endpoint "$body" 2>/dev/null)" && [ -n "$norm" ]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null || true
        printf '%s\n' "$norm" >"$CACHE_FILE" 2>/dev/null || true
        printf '%s\n' "$norm"
        return 0
      fi
      fail_note="the usage endpoint answered 200 with a body this reader could not understand"
    elif [ -z "$http" ]; then
      fail_note="the usage endpoint could not be reached"
    else
      fail_note="the usage endpoint answered HTTP $http"
    fi
  fi

  # 5. degrade: a recent cache, then a statusLine snapshot, then unknown.
  if cached="$(cached_read "$CACHE_STALE_SECONDS" stale 2>/dev/null)" && [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    return 0
  fi
  local sl
  if sl="$(normalise_statusline 2>/dev/null)" && [ -n "$sl" ]; then
    printf '%s\n' "$sl"
    return 0
  fi
  [ -n "$fail_note" ] || fail_note="no usage number could be read"
  # One override hint, never two (the note may already carry one).
  case "$fail_note" in
    *--five-hour*) unknown_read "$fail_note" ;;
    *)             unknown_read "$fail_note — or pass --five-hour N --weekly N" ;;
  esac
}

# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------
human_line() {
  READ_FILE="$1" NOW="$NOW" python3 <<'PY'
import json, os, datetime
d = json.load(open(os.environ["READ_FILE"]))
now = int(os.environ["NOW"])

def pctstr(v):
    if v is None:
        return None
    return ("%d" % v) if float(v) == int(v) else ("%.1f" % v)

def countdown(ts):
    if ts is None:
        return None
    secs = ts - now
    if secs <= 0:
        return "now"
    mins = int(secs // 60)
    h, m = divmod(mins, 60)
    return "in %dh %02dm" % (h, m) if h else "in %dm" % m

def clock(ts, fmt):
    if ts is None:
        return None
    return datetime.datetime.fromtimestamp(ts).strftime(fmt)

def today_aware_clock(ts):
    """Same rule as the gate verdict: a bare clock time for a reset later today,
    a day marker when it is not today. A 5-hour window read at 22:30 resets at
    01:20 TOMORROW, and "resets 01:20" reads as already past."""
    if ts is None:
        return None
    when = datetime.datetime.fromtimestamp(ts)
    return when.strftime("%H:%M" if when.date() == datetime.datetime.fromtimestamp(now).date()
                         else "%a %H:%M")

parts = []
f = d.get("fiveHour") or {}
if pctstr(f.get("pct")) is None:
    parts.append("5h: unknown")
else:
    seg = "5h: %s%% used" % pctstr(f["pct"])
    if f.get("resetsAt"):
        seg += " · resets %s (%s)" % (today_aware_clock(f["resetsAt"]), countdown(f["resetsAt"]))
    parts.append(seg)

w = d.get("weekly") or {}
if pctstr(w.get("pct")) is None:
    parts.append("weekly: unknown")
else:
    seg = "weekly: %s%% used" % pctstr(w["pct"])
    if w.get("resetsAt"):
        seg += " · resets %s" % clock(w["resetsAt"], "%a %H:%M")
    parts.append(seg)

line = "  ·  ".join(parts)
tail = []
if d.get("source") != "endpoint":
    tail.append(str(d.get("source")))
if d.get("note"):
    tail.append(str(d["note"]))
if tail:
    line += "  ·  (" + "; ".join(tail) + ")"
print(line.replace("\n", " "))
PY
}

gate_verdict() {
  READ_FILE="$1" NOW="$NOW" T_GO="$2" T_GRACE="$3" T_MINS="$4" T_WEEK="$5" \
  AS_JSON="$OPT_JSON" \
  PY_LIB_DIR="$PY_LIB_DIR" python3 <<'PY'
import json, os, re, sys, datetime
sys.path.insert(0, os.environ["PY_LIB_DIR"])
from chainlib import as_epoch, as_pct
d = json.load(open(os.environ["READ_FILE"]))
now = int(os.environ["NOW"])
go, grace, grace_mins, week_ask = (float(os.environ[k]) for k in ("T_GO", "T_GRACE", "T_MINS", "T_WEEK"))

f = d.get("fiveHour") or {}
w = d.get("weekly") or {}
# as_pct, not `.get("pct")`. This is the verdict chokepoint, and it is the last
# thing standing between a number and a GO — so it applies the same rule the
# argument parser applies, from the same function, rather than trusting that
# whichever path produced this document bothered to look.
five, week = as_pct(f.get("pct")), as_pct(w.get("pct"))

def num(v):
    """The number SHOWN must be the number COMPARED. Rounding to one decimal
    made 70.001 print as "70.0% used … needs ≤70%" next to a HOLD, which reads
    as a bug to anyone who does not know a digit was dropped (and the endpoint
    returns floats, so it is reachable for real). repr() is the shortest string
    that round-trips the float; a whole percentage still prints as "70"."""
    if v is None:
        return None
    v = float(v)
    return ("%d" % v) if v == int(v) else repr(v)

def mins_to(ts):
    return None if ts is None else (ts - now) / 60.0

def pretty(ts):
    m = mins_to(ts)
    if m is None:
        return "reset time unknown"
    if -1 <= m <= 0:
        return "resets now"
    if m < 0:
        # Not a window about to roll over: a reset time in the PAST means the
        # number is stale or wrong, and saying "resets now" hid that.
        when = datetime.datetime.fromtimestamp(ts)
        return "its reset time (%s) is already past" % when.strftime("%a %H:%M")
    h, mm = divmod(int(m), 60)
    rel = "in %dh %02dm" % (h, mm) if h else "in %dm" % mm
    # A bare "23:00" read at 22:00 looks an hour away or already past, and a
    # 5-hour window CAN reset tomorrow. So when the reset is not today (local
    # time) carry a day marker, exactly as the weekly line on `read` does.
    when = datetime.datetime.fromtimestamp(ts)
    fmt = "%H:%M" if when.date() == datetime.datetime.fromtimestamp(now).date() else "%a %H:%M"
    return "resets %s (%s)" % (when.strftime(fmt), rel)

# INVARIANT: a guard that cannot be EVALUATED is never a GO.
#
# This is the single decision point, and it is deliberately the only place the
# rule lives — four input paths feed it and a fifth will, so the rule belongs
# here rather than in each of them. An unreadable FIVE-HOUR number already
# failed safe; an unreadable WEEKLY number failed OPEN, printing "weekly
# unreported" beside exit 0 while the real weekly figure was 95%. An unattended
# chain reads only the exit code, so that asymmetry was the whole defect. Eight
# distinct shapes of seven_day.utilization reached a GO this way (a string,
# null, true, a bare number, {}, a renamed key, the key absent, a scoped
# limits[] entry), and the same shapes reached one through the cache and the
# statusLine. They are one defect, and this is one cure.
#
# NOTE FOR THE CAPTAIN: if the real endpoint ever omits `seven_day` from an
# otherwise valid 200, the gate now answers UNKNOWN (4) where it used to answer
# GO (0). That is the intended, fail-safe direction — the chain stops and asks
# rather than running on a guard it could not check — but it IS a behaviour
# change on a legitimate response, and `--five-hour N --weekly N` is the manual
# way past it.
# The source mark and the stale marker are computed HERE, above the two UNKNOWN
# exits, rather than just before the HOLD/ASK/GO prints where they used to be.
# Nothing about the prose changes (only those three lines ever used `tail`), but
# `--json` has to be able to carry them on an UNKNOWN too: "no number I could
# read, and the last numbers I had were 12 minutes old" is two facts, and the
# unattended caller this JSON exists for wants both.
marks = []
if d.get("source") != "endpoint":
    marks.append("source: %s" % d.get("source"))
stale = re.search(r"stale (\d+) ?min", str(d.get("note") or ""))
stale_minutes = int(stale.group(1)) if stale else None
if stale:
    marks.append("stale %s min" % stale.group(1))
tail = (" [" + "; ".join(marks) + "]") if marks else ""

AS_JSON = os.environ.get("AS_JSON") == "1"


def emit(word, rc, why):
    """The ONE exit from this block, in whichever of the two languages the
    caller asked for.

    The prose is assembled exactly as it always was — "<WORD> — <why>" — so
    `gate` with no --json is what it printed before; the captain explicitly kept
    the shortened GO line and it is not this change's business.

    The JSON is the SAME verdict word, the SAME exit code and the SAME sentence,
    plus the numbers, in fields named as `read --json` already names them
    (source / readAt / fiveHour{pct,resetsAt} / weekly{pct,resetsAt} / note) so a
    caller learns one vocabulary and not two. `pct` is the as_pct'd value for the
    same reason the verdict uses it: the JSON must not publish a number the
    verdict refused to believe.

    Why it exists at all: S199 loops this gate unattended, so it must not have to
    parse prose — which is also exactly why round 2 REFUSED `gate --json` rather
    than accepting it and printing prose at something expecting JSON.
    """
    if AS_JSON:
        print(json.dumps({
            "verdict": word,
            "exitCode": rc,
            "reason": why,
            "source": d.get("source") if isinstance(d.get("source"), str) else "unknown",
            "readAt": as_epoch(d.get("readAt")),
            "fiveHour": {"pct": five, "resetsAt": as_epoch(f.get("resetsAt"))},
            "weekly": {"pct": week, "resetsAt": as_epoch(w.get("resetsAt"))},
            "note": d.get("note") if isinstance(d.get("note"), str) else "",
            # null, not absent, when the numbers are live: a stable shape is
            # easier to consume than a key that comes and goes.
            "staleMinutes": stale_minutes,
            "thresholds": {"fiveHourGo": go, "fiveHourGrace": grace,
                           "graceMinutes": grace_mins, "weeklyAsk": week_ask},
        }))
    else:
        print("%s — %s" % (word, why))
    sys.exit(rc)


reason = d.get("note") or "no reason recorded"

# THE NO-WINDOW BRANCH. It sits ABOVE the five-hour UNKNOWN and below nothing,
# and it is deliberately the narrowest possible hole in that fail-safe: it fires
# only when the document says, explicitly, `fiveHour.reported == False` — which
# only the endpoint parser writes, and only when the account sent no five_hour
# object and no session-kind limits[] entry either.
#
# Why that is NOT a relaxation of section 25's invariant. That invariant is "a
# guard that cannot be EVALUATED is never a GO". A window the plan does not have
# is not an unevaluable guard; it is an absent CONSTRAINT, and the weekly limit
# — which IS readable, and is checked right here — is then the only guard there
# is. The distinction is the difference between "I could not read the speed
# limit" and "there is no speed limit on this road".
#
# `is False`, not falsy: a cache document written by the previous version has no
# `reported` key at all, and `.get()` returns None for it. None must read as "I
# do not know, so fail safe", exactly as before the change. The upgrade boundary
# fails in the safe direction.
#
# `week is not None` is belt and braces — the endpoint parser already refuses a
# document with neither number — because the expensive direction here is a GO
# with nothing at all evaluated.
if five is None and f.get("reported") is False and week is not None:
    nowin = "this plan reports no 5-hour window, so the weekly limit is the only guard"
    if week >= week_ask:
        emit("ASK", 3, "weekly limit at %s%% used (≥%g%% asks before every "
                       "session); %s%s" % (num(week), week_ask, nowin, tail))
    emit("GO", 0, "weekly at %s%% used, %s; %s%s"
         % (num(week), pretty(w.get("resetsAt")), nowin, tail))

if five is None:
    emit("UNKNOWN", 4, "no 5-hour usage number could be read: %s" % reason)
if week is None:
    emit("UNKNOWN", 4, "no weekly usage number could be read, so the weekly "
                       "limit cannot be checked: %s" % reason)

left = mins_to(f.get("resetsAt"))
# `0 <= left` matters: `left` was unbounded below, so for a window whose reset
# time was already in the past `left < grace_mins` was trivially true and
# 80% with a reset two days ago printed "GO — ... resets now".
five_ok = (five <= go) or (five <= grace and left is not None and 0 <= left < grace_mins)
week_tripped = week >= week_ask

# `week` is never None here: the invariant above already refused that case.
weekbit = "weekly at %s%% used" % num(week)

if not five_ok:
    emit("HOLD", 2, "5-hour window at %s%% used, %s (needs ≤%g%%, or ≤%g%% within %gm); %s%s"
         % (num(five), pretty(f.get("resetsAt")), go, grace, grace_mins, weekbit, tail))
if week_tripped:
    emit("ASK", 3, "weekly limit at %s%% used (≥%g%% asks before every session); 5-hour window at %s%% used, %s%s"
         % (num(week), week_ask, num(five), pretty(f.get("resetsAt")), tail))
# The threshold recital stays on HOLD (where it explains the refusal) and the
# ASK line keeps its own weekly clause, but a GO does not recite them: the text
# is constant, it is the least interesting thing on a line read in a morning
# log, and dropping it brings GO from ~115 characters to ~73. To revert, put
# " (needs ≤%g%%, or ≤%g%% within %gm)" back after `pretty(...)` with go,
# grace and grace_mins, as the HOLD print above still does.
emit("GO", 0, "5-hour window at %s%% used, %s; %s%s"
     % (num(five), pretty(f.get("resetsAt")), weekbit, tail))
PY
}

# gate_unknown_json <read-file> <reason> -> the same JSON shape gate_verdict
# emits, with the UNKNOWN verdict, for the one case gate_verdict cannot speak
# for: gate_verdict itself fell over. The prose path has had this net since
# round 3 (an unexpected internal error DEGRADES to UNKNOWN instead of escaping
# as exit 1 with a traceback and no verdict word); --json needs the same net, or
# a caller asking for JSON gets a prose line on the very inputs it most needs to
# survive.
gate_unknown_json() {
  GU_READ="$1" GU_REASON="$2" GU_GO="$T_GO" GU_GRACE="$T_GRACE" \
  GU_MINS="$T_MINS" GU_WEEK="$T_WEEK" PY_LIB_DIR="$PY_LIB_DIR" python3 <<'PY'
import json, os, re, sys
sys.path.insert(0, os.environ["PY_LIB_DIR"])
from chainlib import as_epoch, as_pct
try:
    d = json.load(open(os.environ["GU_READ"]))
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}


def window(key):
    o = d.get(key)
    o = o if isinstance(o, dict) else {}
    return {"pct": as_pct(o.get("pct")), "resetsAt": as_epoch(o.get("resetsAt"))}


def thr(key, default):
    try:
        return float(os.environ[key])
    except (KeyError, TypeError, ValueError):
        return default


note = d.get("note") if isinstance(d.get("note"), str) else ""
m = re.search(r"stale (\d+) ?min", note)
print(json.dumps({
    "verdict": "UNKNOWN",
    "exitCode": 4,
    "reason": os.environ.get("GU_REASON") or "no reason recorded",
    "source": d.get("source") if isinstance(d.get("source"), str) else "unknown",
    "readAt": as_epoch(d.get("readAt")),
    "fiveHour": window("fiveHour"),
    "weekly": window("weekly"),
    "note": note,
    "staleMinutes": int(m.group(1)) if m else None,
    "thresholds": {"fiveHourGo": thr("GU_GO", 70.0),
                   "fiveHourGrace": thr("GU_GRACE", 80.0),
                   "graceMinutes": thr("GU_MINS", 45.0),
                   "weeklyAsk": thr("GU_WEEK", 70.0)},
}))
PY
}

# ---------------------------------------------------------------------------
# argv
# ---------------------------------------------------------------------------
# A value-taking flag's value is validated HERE, in the parser, because every
# way of being lenient about it was a real defect (all three found by driving
# the product from the outside, 2026-09-11):
#   * a MISSING value span the parser forever — `shift 2` with one argument left
#     fails, shifts nothing, and the loop re-reads the same flag. It hung a
#     session twice. An unknown flag already exited 64; so does this now.
#   * a NON-NUMERIC value was silently dropped. `--weekly abc` deleted the
#     weekly ASK guard and printed GO; `--five-hour abc` printed UNKNOWN
#     blaming the (suppressed) account read. One typo, a wrong verdict.
#   * an OUT-OF-RANGE value printed "5-hour window at -5% used" and went.
# An empty-but-present value (`--five-hour "$EMPTY"`) is the same usage error as
# a missing one: it is a typo either way, and it used to read as UNKNOWN.
# These errors print ONE actionable line, not the usage block — the caller knows
# the flag, it is the value that is wrong.

need_value() { # need_value <flag> <args-remaining> <value>
  [ "$2" -ge 2 ] || die "$1 needs a value"
  [ -n "$3" ] || die "$1 needs a value (an empty one was given)"
}

check_number() { # check_number <flag> <value> <min> [max] [why-the-max]
  local flag="$1" val="$2" lo="$3" hi="${4:-}" why="${5:-}"
  [[ "$val" =~ ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]] ||
    die "$flag needs a number, not '$val'"
  awk -v v="$val" -v lo="$lo" 'BEGIN{exit !(v+0 >= lo+0)}' ||
    die "$flag may not be below $lo (got '$val')"
  [ -z "$hi" ] ||
    awk -v v="$val" -v hi="$hi" 'BEGIN{exit !(v+0 <= hi+0)}' ||
    die "$flag may not be above $hi${why:+ $why} (got '$val')"
}

VERB="read"
OPT_JSON=0
OPT_FRESH=0
OPT_FIVE=""
OPT_WEEKLY=""
OPT_RESETS_IN=""

if [ $# -gt 0 ]; then
  case "$1" in
    read|gate|config) VERB="$1"; shift ;;
    help|-h|--help)   usage_text; exit 0 ;;
    --*)              ;;                      # bare flags: the default verb
    *)                usage_text >&2; die "unknown verb: $1" ;;
  esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --fresh)                # The 180 s poll floor is the DEFAULT and stays
                            # the default; this steps over it for one call.
                            # S199's chain re-gates before every session, and a
                            # session is long, so serving that gate from a cache
                            # warmed before the previous session would answer
                            # the new question with the old numbers. It does not
                            # loosen anything else: still one request, still no
                            # retry loop, still the same degrade order when it
                            # fails, and still written back to the cache.
                            OPT_FRESH=1; shift ;;
    --json)                 # `--json` is legal on BOTH verbs now.
                            # It used to be refused on `gate`, and the refusal
                            # was right at the time: `gate --json` had exited 0
                            # and printed PROSE, so anyone scripting it parsed
                            # prose and never found out. The refusal was the
                            # honest holding answer until a real JSON mode
                            # existed. It exists (captain's ruling 2026-09-12 —
                            # S199 loops this gate unattended and must not parse
                            # prose), so the refusal has done its job and gone.
                            # `gate` WITHOUT --json is untouched.
                            OPT_JSON=1; shift ;;
    --five-hour)            need_value "$1" $# "${2:-}"
                            check_number "$1" "$2" 0 100
                            OPT_FIVE="$2"; shift 2 ;;
    --weekly)               need_value "$1" $# "${2:-}"
                            check_number "$1" "$2" 0 100
                            OPT_WEEKLY="$2"; shift 2 ;;
    --five-hour-resets-in)  need_value "$1" $# "${2:-}"
                            check_number "$1" "$2" 0 600 \
                              "— the 5-hour window is five hours, so 600 minutes is already generous headroom"
                            OPT_RESETS_IN="$2"; shift 2 ;;
    -h|--help)              usage_text; exit 0 ;;
    *)                      usage_text >&2; die "unknown option: $1" ;;
  esac
done

# A manual override is a PAIR. Omitting one half used to be silently accepted,
# and it failed in OPPOSITE directions: `--five-hour 50` alone printed
# "GO … weekly unreported" and exited 0 — the weekly ASK guard deleted by
# omission, and the real account read suppressed along with it — while
# `--weekly 10` alone fell through to UNKNOWN. Round 1 closed the TYPO route
# (`--weekly abc` -> 64) and left this one open; an unattended chain is one
# missing flag away from a false GO. Both halves are now the same usage error
# the help text already describes (`--five-hour N --weekly N`).
# `--five-hour-resets-in` stays optional, and is only legal alongside a complete
# pair — on its own it is not an override at all.
if [ -n "$OPT_FIVE" ] || [ -n "$OPT_WEEKLY" ] || [ -n "$OPT_RESETS_IN" ]; then
  missing=""
  [ -n "$OPT_FIVE" ]   || missing="--five-hour"
  [ -n "$OPT_WEEKLY" ] || missing="${missing:+$missing and }--weekly"
  [ -z "$missing" ] ||
    die "a manual override is a pair — $missing missing (usage: --five-hour N --weekly N [--five-hour-resets-in MINUTES])"
fi

# The clock is an input like any other. CHAIN_NOW=abc reached every python
# block as int("abc") and came out as exit 1 with a traceback and no verdict
# word — outside the exit contract entirely. It is checked here, after the
# parser (so `help` still works) and before anything uses it.
case "$NOW" in
  ''|*[!0-9]*) die "usage.sh: CHAIN_NOW needs a whole number of epoch seconds, not $NOW" ;;
esac

# The DESTINATION is an input like any other, and the only input that can make
# this script hand the captain's OAuth bearer to a stranger (BUG-088). Checked
# in the same place and for the same reason as CHAIN_NOW above: after the parser
# so `help` still works, before anything can use it. A bad one is a usage error,
# never a quietly honoured request.
usage_url_ok "$USAGE_URL" ||
  die "usage.sh: refusing the usage URL '$USAGE_URL' — the OAuth bearer may only ever be sent to https://api.anthropic.com (CHAIN_USAGE_URL may change the PATH on that host; to test without a network, stub CHAIN_CURL_BIN)"

read -r T_GO T_GRACE T_MINS T_WEEK <<<"$(read_config)"
# Backstop, not a second validator: read_config is the only python block whose
# output is parsed as four bare numbers, and handing gate_verdict an empty
# string to float() is how a wrong-typed `thresholds` key became exit 1 with a
# traceback. If anything at all came back unusable, the shipped defaults stand
# and say so.
for _t in "$T_GO" "$T_GRACE" "$T_MINS" "$T_WEEK"; do
  case "$_t" in
    ''|*[!0-9.]*)
      printf 'usage.sh: the thresholds could not be read - using the built-in defaults 70/80/45/70\n' >&2
      T_GO=70; T_GRACE=80; T_MINS=45; T_WEEK=70
      break ;;
  esac
done

case "$VERB" in
  config)
    printf 'thresholds in force (%s)\n' \
      "$([ -f "$CONFIG_FILE" ] && printf '%s' "$CONFIG_FILE" || printf 'built-in defaults')"
    printf '  GO      when the 5-hour window is <= %s%% used\n' "$T_GO"
    printf '  GO      also when it is <= %s%% used AND resets in under %s minutes\n' "$T_GRACE" "$T_MINS"
    printf '  ASK     when the weekly limit is >= %s%% used (asked before every session)\n' "$T_WEEK"
    printf '  HOLD    otherwise\n'
    printf '  UNKNOWN when no read succeeded and no override was given\n'
    printf 'precedence: HOLD outranks ASK, ASK outranks GO\n'
    printf 'exit codes: 0 GO · 2 HOLD · 3 ASK · 4 UNKNOWN\n'
    ;;
  read)
    resolve_usage >"$TMPD/read.json" 2>/dev/null
    [ -s "$TMPD/read.json" ] ||
      unknown_read "the usage reader produced no document" >"$TMPD/read.json" 2>/dev/null
    if [ "$OPT_JSON" = 1 ]; then
      cat "$TMPD/read.json"
    else
      human_line "$TMPD/read.json" >"$TMPD/human.txt" 2>/dev/null
      if [ -s "$TMPD/human.txt" ]; then
        cat "$TMPD/human.txt"
      else
        printf '5h: unknown  ·  weekly: unknown  ·  (the usage line could not be rendered)\n'
        exit 4
      fi
    fi
    src="$(READ_FILE="$TMPD/read.json" python3 -c 'import json, os
try:
    print((json.load(open(os.environ["READ_FILE"])) or {}).get("source") or "unknown")
except Exception:
    print("unknown")' 2>/dev/null)"
    [ -n "$src" ] || src="unknown"
    [ "$src" = "unknown" ] && exit 4
    exit 0
    ;;
  gate)
    # INVARIANT: every exit from this tool is 0 / 2 / 3 / 4 / 64, always with a
    # verdict word or a usage message. Six inputs used to exit 1 with a Python
    # traceback and no verdict at all, which is the most dangerous shape after a
    # false GO — a caller testing `rc -ne 0` sees a refusal, one testing
    # `rc -eq 2` sees nothing it recognises, and nobody sees a reason. Each
    # specific crash is cured upstream; this is the net under all of them, so an
    # unexpected internal error DEGRADES to UNKNOWN instead of escaping.
    resolve_usage >"$TMPD/read.json" 2>/dev/null
    [ -s "$TMPD/read.json" ] ||
      unknown_read "the usage reader produced no document" >"$TMPD/read.json" 2>/dev/null
    gate_verdict "$TMPD/read.json" "$T_GO" "$T_GRACE" "$T_MINS" "$T_WEEK" \
      >"$TMPD/verdict.out" 2>"$TMPD/verdict.err"
    rc=$?
    case "$rc" in
      0|2|3|4)
        if [ -s "$TMPD/verdict.out" ]; then
          cat "$TMPD/verdict.out"
          exit "$rc"
        fi ;;
    esac
    # The LAST line of a python traceback is its exception message, which is the
    # one useful line; the word "Traceback" itself never reaches the caller.
    reason="$(tail -n 1 "$TMPD/verdict.err" 2>/dev/null | tr -d "\047")"
    case "$reason" in *[Tt]raceback*) reason="" ;; esac
    if [ "$OPT_JSON" = 1 ]; then
      # A caller that asked for JSON gets JSON even here — especially here.
      # Two nets deep: if even the JSON renderer cannot run, a literal object is
      # printed, because "always one parseable object" is the whole contract.
      gate_unknown_json "$TMPD/read.json" \
        "the gate could not be evaluated (internal error, exit $rc): ${reason:-no reason recorded}" \
        >"$TMPD/verdict.json" 2>/dev/null
      if [ -s "$TMPD/verdict.json" ]; then
        cat "$TMPD/verdict.json"
      else
        printf '{"verdict":"UNKNOWN","exitCode":4,"reason":"the gate could not be evaluated and the JSON renderer also failed","source":"unknown","readAt":null,"fiveHour":{"pct":null,"resetsAt":null},"weekly":{"pct":null,"resetsAt":null},"note":"","staleMinutes":null,"thresholds":{}}\n'
      fi
    else
      printf 'UNKNOWN — the gate could not be evaluated (internal error, exit %s): %s\n' \
        "$rc" "${reason:-no reason recorded}"
    fi
    exit 4
    ;;
esac
