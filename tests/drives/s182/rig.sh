#!/usr/bin/env bash
# S182 TESTER RIG — zero-spend drive harness for the no-runner wall.
#
# Every drive runs with a PATH shim providing COUNTING fake `claude` and
# `copilot` executables. This is not an env var on purpose: a persisted
# state.json workerBin beats LCARS_WORKER_BIN, so only PATH is authoritative.
# The SPEND FUSE below refuses to run at all if the shim is not there, because
# an empty shim dir puts the REAL `claude` back on PATH and bills the captain.
set -u

LCARS_SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
RUN_SH="$LCARS_SRC/skills/lcars-run/run.sh"
INIT_SH="$LCARS_SRC/skills/lcars-init/init.sh"
UPDATE_SH="$LCARS_SRC/skills/lcars-update/update.sh"

# --- shim ------------------------------------------------------------------
make_shim() { # calls-log → echoes shim dir holding counting claude+copilot
  local log="$1" d b
  d="$(mktemp -d "${TMPDIR:-/tmp}/s182shim.XXXXXX")"
  for b in claude copilot; do
    cat > "$d/$b" <<SH
#!/usr/bin/env bash
# COUNTING FAKE — records every invocation, spends nothing.
# ONE marker line per invocation (args can be multi-line, so counting raw
# lines overcounts); the full argv goes to a sidecar for inspection.
case " \$* " in
  *" --version "*|*" -v "*)
      printf 'PROBE\\t%s\\t--version\\n' "\$(basename "\$0")" >> "$log"
      echo "0.0.0-s182-fake (counting shim)"; exit 0 ;;
esac
printf 'SPAWN\\t%s\\t%s\\n' "\$(basename "\$0")" "\$(printf '%s' "\$*" | head -c 120 | tr '\\n' ' ')" >> "$log"
{ echo "=== \$(basename "\$0") ==="; printf '%s\\n' "\$*"; } >> "$log.argv"
exit 0
SH
    chmod +x "$d/$b"
  done
  echo "$d"
}

# --- SPEND FUSE ------------------------------------------------------------
fuse() { # shim-dir → 0 safe, 1 REFUSE
  local sh="${1:-}"
  if [ -n "$sh" ] && [ -x "$sh/claude" ] && [ -x "$sh/copilot" ]; then return 0; fi
  echo "SPEND FUSE TRIPPED: no counting claude/copilot at '${sh:-<empty>}' — REFUSING (would bill)" >&2
  return 1
}

# --- drives ----------------------------------------------------------------
# All set RC and OUT. All refuse (RC=99) if the fuse trips.
drive() { # repo shim-dir [env pairs…] -- args…
  local r="$1" sh="$2"; shift 2
  fuse "$sh" || { RC=99; OUT="REFUSED-BY-FUSE"; return 0; }
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  OUT="$( cd "$r" && env PATH="$sh:$PATH" LCARS_GH_BIN=true \
            LCARS_GIT_BIN="$(command -v git)" "${envs[@]}" "$@" 2>&1 )"
  RC=$?
}

drive_impl() { # repo shim-dir [env pairs…]
  local r="$1" sh="$2"; shift 2
  drive "$r" "$sh" "$@" -- bash "$RUN_SH" implement-ticket --mission test-001 --ticket t-001
}

drive_init() { # repo shim-dir [env pairs…]
  local r="$1" sh="$2"; shift 2
  drive "$r" "$sh" "$@" -- bash "$INIT_SH"
}

# --- fixtures --------------------------------------------------------------
# mission_at_implement: the on-disk state a real Schedule stage leaves behind.
# Shaped after tests/red-gate-preflight.test.sh:new_impl_mission.
mission_at_implement() { # repo [mission-id]
  local r="$1" m="${2:-test-001}"
  mkdir -p "$r/.git/lcars/missions/$m/tickets/t-001"
  # PRETTY-PRINTED, one key per line, `{` alone on line 1 — the shape
  # lcars-file/file.sh actually writes. state_set_raw/state_set_str insert
  # after NR==1, so a one-line fixture produces INVALID JSON (a fixture bug,
  # not a product bug — tests/red-gate-preflight.test.sh has that one-liner).
  cat > "$r/.git/lcars/missions/$m/state.json" <<JSON
{
  "id": "$m",
  "type": "feature",
  "title": "greenfield drive",
  "stage": "implement",
  "created": "2026-09-04T00:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": null,
  "branch": "lcars/$m",
  "base": "main"
}
JSON
  cat > "$r/.git/lcars/missions/$m/approved-plan.json" <<'JSON'
{ "tickets": [ { "id": "t-001", "title": "t", "description": "d",
                 "acceptanceCriteria": ["a"] } ] }
JSON
  # waves.json in emit_waves_json's CANONICAL shape — a top-level ARRAY of
  # { wave, tickets:[ {id, issue} ] }. parse_waves_table is line-oriented and
  # reads "wave": N then each "id": "…" under it; a hand-rolled
  # { "waves": [ {"wave":1,"tickets":["t-001"]} ] } parses to NOTHING.
  cat > "$r/.git/lcars/missions/$m/waves.json" <<'JSON'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  }
]
JSON
}

mdir()  { echo "$1/.git/lcars/missions/test-001"; }
park_text() { cat "$(mdir "$1")/pending.json" "$(mdir "$1")/state.json" 2>/dev/null; }
# SPAWNS = real worker hires. PROBES = `--version` capability checks (not spend).
# (grep -c exits 1 on zero matches, so `|| echo 0` would print TWICE — use awk.)
calls()  { awk '/^SPAWN/{n++} END{print n+0}' "$1" 2>/dev/null || echo 0; }
probes() { awk '/^PROBE/{n++} END{print n+0}' "$1" 2>/dev/null || echo 0; }

# --- make_shim_compliant ---------------------------------------------------
# A counting fake that ALSO obeys the harness's "write your output to EXACTLY:
# <path>" contract, so a drive can get PAST the infra/context-pack worker and
# reach the ticket loop. Still spends nothing; still counts every hire.
# Needed because the Implement STAGE driver hires a context-pack worker before
# it ever reaches a ticket — a plain no-op fake stalls the drive there and hides
# what the ticket loop would have done.
make_shim_compliant() { # calls-log → echoes shim dir
  local log="$1" d b
  d="$(mktemp -d "${TMPDIR:-/tmp}/s182shimc.XXXXXX")"
  for b in claude copilot; do
    cat > "$d/$b" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --version "*|*" -v "*)
      printf 'PROBE\t%s\t--version\n' "\$(basename "\$0")" >> "$log"
      echo "0.0.0-s182-fake (counting shim)"; exit 0 ;;
esac
printf 'SPAWN\t%s\t%s\n' "\$(basename "\$0")" "\$(printf '%s' "\$*" | head -c 120 | tr '\n' ' ')" >> "$log"
{ echo "=== \$(basename "\$0") ==="; printf '%s\n' "\$*"; } >> "$log.argv"
# Obey "… to EXACTLY: <abs path>" so the harness sees real worker output.
printf '%s' "\$*" | grep -oE 'EXACTLY: /[^[:space:]]+' | sed 's/^EXACTLY: //' \
  | while read -r p; do
      mkdir -p "\$(dirname "\$p")"
      printf '# stub written by the S182 counting fake worker\n\nNo real model ran.\n' > "\$p"
    done
exit 0
SH
    chmod +x "$d/$b"
  done
  echo "$d"
}
